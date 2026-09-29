/* SPDX-License-Identifier: MIT */

#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <spa/buffer/buffer.h>
#include <spa/buffer/meta.h>
#include <spa/param/format.h>
#include <spa/param/ndarray-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include <pipewire/pipewire.h>

#define VECTOR_LENGTH 2u
#define FAST_RATE 1000u
#define SLOW_RATE 100u
#define SAMPLES 10u
#define EXTRA_SAMPLES 4u
#define TOTAL_SAMPLES (SAMPLES + EXTRA_SAMPLES)
#define INITIAL_HELD_OUTPUTS (SAMPLES * HOLD_CYCLES)
#define FULL_HELD_OUTPUTS (INITIAL_HELD_OUTPUTS + 2u * HOLD_CYCLES)
#define HOLD_CYCLES 10u
#define EXPIRY_CHECK_CYCLE 120u
#define PRIMARY_SCHEMA "org.pipewireao.rtc.latest-hold.primary/1"
#define SLOW_SCHEMA "org.pipewireao.rtc.latest-hold.slow/1"

struct fixture {
	struct pw_main_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_stream *primary_source;
	struct pw_stream *source;
	struct pw_stream *sink;
	struct pw_stream *command_sink;
	struct spa_hook source_listener;
	struct spa_hook primary_listener;
	struct spa_hook sink_listener;
	struct spa_hook command_listener;
	struct spa_source *control;
	atomic_uint source_cycles;
	atomic_uint primary_cycles;
	atomic_uint source_published;
	atomic_uint extra_requests;
	atomic_uint source_empty;
	atomic_uint sink_received;
	atomic_uint commands_received;
	atomic_uint primary_rate_num;
	atomic_uint primary_rate_denom;
	atomic_uint primary_quantum;
	atomic_uint input_data_cycle;
	atomic_uint input_primary_sequence;
	atomic_uint_fast64_t last_header_sequence;
	atomic_uint_fast64_t first_command_sequence;
	atomic_uint_fast64_t last_command_sequence;
	atomic_uint command_gaps;
	atomic_uint source_buffers_added;
	atomic_uint source_buffers_removed;
	atomic_uint observer_buffers_added;
	atomic_uint observer_buffers_removed;
	atomic_uint source_progress_sequence;
	atomic_uint primary_progress_sequence;
	atomic_uint sink_progress_sequence;
	atomic_uint command_progress_sequence;
	atomic_bool have_header;
	atomic_bool have_command_sequence;
	atomic_bool next_sample_enabled;
	atomic_bool command_gap_armed;
	atomic_bool active;
	atomic_bool started;
	atomic_bool failed;
};

static const uint8_t domain[SPA_META_ACQUISITION_DOMAIN_SIZE] = { 0x42 };
static const uint8_t primary_domain[SPA_META_ACQUISITION_DOMAIN_SIZE] = { 0x24 };

static void fail(struct fixture *data, const char *message)
{
	if (!atomic_exchange_explicit(&data->failed, true, memory_order_acq_rel))
		fprintf(stderr, "%s\n", message);
	pw_main_loop_quit(data->loop);
}

static bool increment_counter(atomic_uint *counter, uint32_t *value)
{
	unsigned int current = atomic_load_explicit(counter, memory_order_seq_cst);

	do {
		if (current == UINT_MAX)
			return false;
	} while (!atomic_compare_exchange_weak_explicit(counter, &current,
			current + 1u, memory_order_seq_cst, memory_order_seq_cst));
	*value = current + 1u;
	return true;
}

static void progress_write_begin(atomic_uint *sequence)
{
	(void)atomic_fetch_add_explicit(sequence, 1u, memory_order_seq_cst);
}

static void progress_write_end(atomic_uint *sequence)
{
	(void)atomic_fetch_add_explicit(sequence, 1u, memory_order_seq_cst);
}

static bool progress_read_begin(const atomic_uint *sequence, uint32_t *value)
{
	*value = atomic_load_explicit(sequence, memory_order_seq_cst);
	return (*value & 1u) == 0u;
}

static bool progress_read_end(const atomic_uint *sequence, uint32_t value)
{
	return atomic_load_explicit(sequence, memory_order_seq_cst) == value;
}

static struct spa_pod *build_format(struct spa_pod_builder *builder,
		uint32_t rate, const char *schema)
{
	static const uint32_t shape[] = { VECTOR_LENGTH };
	struct spa_pod_frame object;

	spa_pod_builder_push_object(builder, &object, SPA_TYPE_OBJECT_Format,
			SPA_PARAM_EnumFormat);
	spa_pod_builder_add(builder,
			SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_application),
			SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_ndarray),
			SPA_FORMAT_NDARRAY_elementType, SPA_POD_Id(SPA_ELEMENT_TYPE_F32_LE),
			SPA_FORMAT_NDARRAY_shape, SPA_POD_Array(sizeof(uint32_t),
				SPA_TYPE_Int, SPA_N_ELEMENTS(shape), shape),
			SPA_FORMAT_NDARRAY_layout, SPA_POD_Id(SPA_NDARRAY_LAYOUT_ROW_MAJOR),
			SPA_FORMAT_NDARRAY_rate, SPA_POD_Fraction(&SPA_FRACTION(rate, 1u)),
			SPA_FORMAT_NDARRAY_schema, SPA_POD_String(schema), 0);
	return spa_pod_builder_pop(builder, &object);
}

static struct spa_pod *build_header_meta(struct spa_pod_builder *builder)
{
	return spa_pod_builder_add_object(builder, SPA_TYPE_OBJECT_ParamMeta,
			SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
			SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
}

static struct spa_pod *build_acquisition_meta(struct spa_pod_builder *builder)
{
	struct spa_pod_frame object;

	spa_pod_builder_push_object(builder, &object, SPA_TYPE_OBJECT_ParamMeta,
			SPA_PARAM_Meta);
	spa_pod_builder_add(builder, SPA_PARAM_META_type,
			SPA_POD_Id(SPA_META_Acquisition), SPA_PARAM_META_size,
			SPA_POD_Int(sizeof(struct spa_meta_acquisition)), 0);
	spa_pod_builder_prop(builder, SPA_PARAM_META_features,
			SPA_POD_PROP_FLAG_MANDATORY);
	spa_pod_builder_int(builder, SPA_META_FEATURE_ACQUISITION_VERSION_2);
	return spa_pod_builder_pop(builder, &object);
}

static bool update_stream_format(struct fixture *data, struct pw_stream *stream,
		uint32_t rate, const char *schema, const char *label)
{
	uint8_t pods[512];
	struct spa_pod_builder builder;
	struct spa_pod *format;
	const struct spa_pod *params[1];
	int result;

	spa_pod_builder_init(&builder, pods, sizeof(pods));
	format = build_format(&builder, rate, schema);
	if (format == NULL) {
		fail(data, "could not rebuild stream EnumFormat for pool replacement");
		return false;
	}
	params[0] = format;
	result = pw_stream_update_params(stream, params, SPA_N_ELEMENTS(params));
	if (result < 0) {
		fprintf(stderr, "%s EnumFormat update failed: %s\n", label,
			spa_strerror(result));
		fail(data, "could not request stream pool replacement");
		return false;
	}
	return true;
}

static void source_process(void *userdata)
{
	struct fixture *data = userdata;
	struct pw_buffer *buffer;
	struct spa_data *block;
	struct spa_meta_header *header;
	struct spa_meta_acquisition *acquisition;
	uint32_t cycle;
	uint32_t sample;
	float values[VECTOR_LENGTH];

	if (!atomic_load_explicit(&data->started, memory_order_acquire))
		return;
	progress_write_begin(&data->source_progress_sequence);
	if (!increment_counter(&data->source_cycles, &cycle)) {
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source cycle counter overflowed");
		return;
	}
	sample = atomic_load_explicit(&data->source_published, memory_order_relaxed);
	if ((cycle - 1u) % HOLD_CYCLES != 0 || sample >= TOTAL_SAMPLES ||
		(sample >= SAMPLES && !atomic_exchange_explicit(
			&data->next_sample_enabled, false, memory_order_acq_rel))) {
		/* Deliberately do not dequeue or queue a buffer: the output IO remains
		 * SPA_STATUS_NEED_DATA for this slow-cadence callback. */
		if (!increment_counter(&data->source_empty, &sample)) {
			progress_write_end(&data->source_progress_sequence);
			fail(data, "slow source empty-cycle counter overflowed");
			return;
		}
		progress_write_end(&data->source_progress_sequence);
		return;
	}
	buffer = pw_stream_dequeue_buffer(data->source);
	if (buffer == NULL || buffer->buffer == NULL ||
		buffer->buffer->n_datas != 1) {
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source has no writable output buffer");
		return;
	}
	block = &buffer->buffer->datas[0];
	header = spa_buffer_find_meta_data(buffer->buffer, SPA_META_Header,
			sizeof(*header));
	acquisition = spa_buffer_find_meta_data(buffer->buffer,
			SPA_META_Acquisition, sizeof(*acquisition));
	if (block->data == NULL || block->chunk == NULL ||
		block->maxsize < sizeof(values) || header == NULL || acquisition == NULL) {
		(void)pw_stream_queue_buffer(data->source, buffer);
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source negotiated incomplete ndarray storage or metadata");
		return;
	}
	if (!increment_counter(&data->source_published, &sample)) {
		(void)pw_stream_queue_buffer(data->source, buffer);
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source publication counter overflowed");
		return;
	}
	values[0] = (float)sample;
	values[1] = -(float)sample;
	memcpy(block->data, values, sizeof(values));
	block->chunk->offset = 0;
	block->chunk->size = sizeof(values);
	block->chunk->stride = sizeof(float);
	block->chunk->flags = 0;
	*header = (struct spa_meta_header) {
		.flags = SPA_META_HEADER_FLAG_MARKER,
		.offset = 0,
		.pts = 100000 + sample,
		.dts_offset = 0,
		.seq = sample,
	};
	if (!spa_meta_acquisition_init(acquisition) ||
		!spa_meta_acquisition_set_identity(acquisition, domain, 7u, sample)) {
		(void)pw_stream_queue_buffer(data->source, buffer);
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source could not write Acquisition identity");
		return;
	}
	if (pw_stream_queue_buffer(data->source, buffer) < 0) {
		progress_write_end(&data->source_progress_sequence);
		fail(data, "slow source could not publish its sample");
		return;
	}
	atomic_store_explicit(&data->input_primary_sequence,
		atomic_load_explicit(&data->primary_cycles, memory_order_acquire),
		memory_order_seq_cst);
	atomic_store_explicit(&data->input_data_cycle, cycle, memory_order_seq_cst);
	progress_write_end(&data->source_progress_sequence);
}

static void primary_process(void *userdata)
{
	struct fixture *data = userdata;
	struct pw_buffer *buffer;
	struct pw_time time;
	struct spa_data *block;
	struct spa_meta_header *header;
	struct spa_meta_acquisition *acquisition;
	uint32_t sequence;
	float values[VECTOR_LENGTH];

	if (!atomic_load_explicit(&data->started, memory_order_acquire))
		return;
	progress_write_begin(&data->primary_progress_sequence);
	if (pw_stream_get_time_n(data->primary_source, &time, sizeof(time)) == 0) {
		atomic_store_explicit(&data->primary_rate_num, time.rate.num,
			memory_order_seq_cst);
		atomic_store_explicit(&data->primary_rate_denom, time.rate.denom,
			memory_order_seq_cst);
		atomic_store_explicit(&data->primary_quantum, (uint32_t)time.size,
			memory_order_seq_cst);
	}
	buffer = pw_stream_dequeue_buffer(data->primary_source);
	if (buffer == NULL || buffer->buffer == NULL ||
		buffer->buffer->n_datas != 1) {
		progress_write_end(&data->primary_progress_sequence);
		fail(data, "primary source has no writable output buffer");
		return;
	}
	block = &buffer->buffer->datas[0];
	header = spa_buffer_find_meta_data(buffer->buffer, SPA_META_Header,
			sizeof(*header));
	acquisition = spa_buffer_find_meta_data(buffer->buffer,
			SPA_META_Acquisition, sizeof(*acquisition));
	if (block->data == NULL || block->chunk == NULL ||
		block->maxsize < sizeof(values) || header == NULL || acquisition == NULL) {
		(void)pw_stream_queue_buffer(data->primary_source, buffer);
		progress_write_end(&data->primary_progress_sequence);
		fail(data, "primary source negotiated incomplete ndarray storage or metadata");
		return;
	}
	if (!increment_counter(&data->primary_cycles, &sequence)) {
		(void)pw_stream_queue_buffer(data->primary_source, buffer);
		progress_write_end(&data->primary_progress_sequence);
		fail(data, "primary source cycle counter overflowed");
		return;
	}
	values[0] = (float)sequence;
	values[1] = -(float)sequence;
	memcpy(block->data, values, sizeof(values));
	block->chunk->offset = 0;
	block->chunk->size = sizeof(values);
	block->chunk->stride = sizeof(float);
	block->chunk->flags = 0;
	*header = (struct spa_meta_header) {
		.flags = SPA_META_HEADER_FLAG_MARKER,
		.offset = 0,
		.pts = 200000 + sequence,
		.dts_offset = 0,
		.seq = sequence,
	};
	if (!spa_meta_acquisition_init(acquisition) ||
		!spa_meta_acquisition_set_identity(acquisition, primary_domain, 9u, sequence)) {
		(void)pw_stream_queue_buffer(data->primary_source, buffer);
		progress_write_end(&data->primary_progress_sequence);
		fail(data, "primary source could not write Acquisition identity");
		return;
	}
	if (pw_stream_queue_buffer(data->primary_source, buffer) < 0) {
		progress_write_end(&data->primary_progress_sequence);
		fail(data, "primary source could not publish its sample");
		return;
	}
	progress_write_end(&data->primary_progress_sequence);
}

static uint32_t expected_held_sample(uint32_t received)
{
	if (received < INITIAL_HELD_OUTPUTS)
		return received / HOLD_CYCLES + 1u;
	if (received < INITIAL_HELD_OUTPUTS + HOLD_CYCLES)
		return 12u;
	if (received < FULL_HELD_OUTPUTS)
		return 14u;
	return 0u;
}

static void sink_process(void *userdata)
{
	struct fixture *data = userdata;
	struct pw_buffer *buffer;
	struct spa_data *block;
	struct spa_meta_header *header;
	struct spa_meta *meta;
	const struct spa_meta_acquisition *acquisition;
	const float *values;
	uint32_t received, expected_sample;
	uint64_t sequence;

	buffer = pw_stream_dequeue_buffer(data->sink);
	if (buffer == NULL)
		return;
	block = &buffer->buffer->datas[0];
	header = spa_buffer_find_meta_data(buffer->buffer, SPA_META_Header,
			sizeof(*header));
	meta = spa_buffer_find_meta(buffer->buffer, SPA_META_Acquisition);
	acquisition = meta == NULL ? NULL : meta->data;
	received = atomic_load_explicit(&data->sink_received, memory_order_relaxed);
	expected_sample = expected_held_sample(received);
	if (block->data == NULL || block->chunk == NULL ||
		block->chunk->offset > block->maxsize ||
		block->chunk->size != VECTOR_LENGTH * sizeof(float) ||
		block->maxsize - block->chunk->offset < block->chunk->size ||
		header == NULL || !spa_meta_acquisition_is_valid(meta) ||
		acquisition->generation != 7u || acquisition->sequence != expected_sample ||
		memcmp(acquisition->domain, domain, sizeof(domain)) != 0 ||
		received >= FULL_HELD_OUTPUTS) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		fail(data, "hold sink observed an unexpected output or Acquisition identity");
		return;
	}
	sequence = header->seq;
	progress_write_begin(&data->sink_progress_sequence);
	if (atomic_exchange_explicit(&data->have_header, true, memory_order_acq_rel) &&
		sequence <= atomic_load_explicit(&data->last_header_sequence,
			memory_order_relaxed)) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		progress_write_end(&data->sink_progress_sequence);
		fail(data, "hold output Header sequence did not advance");
		return;
	}
	atomic_store_explicit(&data->last_header_sequence, sequence,
		memory_order_seq_cst);
	values = SPA_PTROFF(block->data, block->chunk->offset, const float);
	if (values[0] != (float)expected_sample ||
		values[1] != -(float)expected_sample) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		progress_write_end(&data->sink_progress_sequence);
		fail(data, "hold sink observed a payload outside the retained identity run");
		return;
	}
	if (!increment_counter(&data->sink_received, &received)) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		progress_write_end(&data->sink_progress_sequence);
		fail(data, "hold sink output counter overflowed");
		return;
	}
	progress_write_end(&data->sink_progress_sequence);
	(void)pw_stream_queue_buffer(data->sink, buffer);
}

static void command_sink_process(void *userdata)
{
	struct fixture *data = userdata;
	struct pw_buffer *buffer;
	struct spa_data *block;
	struct spa_meta_header *header;
	struct spa_meta *meta;
	const struct spa_meta_acquisition *acquisition;
	const float *values;
	uint64_t sequence;
	uint32_t commands;

	buffer = pw_stream_dequeue_buffer(data->command_sink);
	if (buffer == NULL)
		return;
	block = &buffer->buffer->datas[0];
	header = spa_buffer_find_meta_data(buffer->buffer, SPA_META_Header,
			sizeof(*header));
	meta = spa_buffer_find_meta(buffer->buffer, SPA_META_Acquisition);
	acquisition = meta == NULL ? NULL : meta->data;
	if (block->data == NULL || block->chunk == NULL ||
		block->chunk->offset > block->maxsize ||
		block->chunk->size != VECTOR_LENGTH * sizeof(float) ||
		block->maxsize - block->chunk->offset < block->chunk->size ||
		header == NULL || !spa_meta_acquisition_is_valid(meta) ||
		acquisition->generation != 9u ||
		memcmp(acquisition->domain, primary_domain, sizeof(primary_domain)) != 0) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		fail(data, "processing graph output did not preserve primary Header or Acquisition provenance");
		return;
	}
	sequence = acquisition->sequence;
	if (header->seq != sequence) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		fail(data, "processing graph output Header sequence did not match primary Acquisition identity");
		return;
	}
	progress_write_begin(&data->command_progress_sequence);
	if (!atomic_exchange_explicit(&data->have_command_sequence, true,
			memory_order_acq_rel)) {
		atomic_store_explicit(&data->first_command_sequence, sequence,
			memory_order_seq_cst);
	} else if (sequence != atomic_load_explicit(
			&data->last_command_sequence, memory_order_relaxed) + 1u) {
		if (sequence > atomic_load_explicit(&data->last_command_sequence,
				memory_order_relaxed) && atomic_exchange_explicit(
				&data->command_gap_armed, false, memory_order_acq_rel)) {
			uint32_t gaps = atomic_load_explicit(&data->command_gaps,
				memory_order_relaxed);

			if (gaps >= 2u || !increment_counter(&data->command_gaps, &gaps)) {
				(void)pw_stream_queue_buffer(data->command_sink, buffer);
				progress_write_end(&data->command_progress_sequence);
				fail(data, "processing graph observed too many command identity gaps");
				return;
			}
		} else {
			fprintf(stderr, "command identity gap: expected %" PRIuFAST64 ", observed %" PRIu64 "\n",
				atomic_load_explicit(&data->last_command_sequence,
					memory_order_relaxed) + 1u, sequence);
			(void)pw_stream_queue_buffer(data->command_sink, buffer);
			progress_write_end(&data->command_progress_sequence);
			fail(data, "processing graph output did not advance through contiguous primary identities");
			return;
		}
	}
	values = SPA_PTROFF(block->data, block->chunk->offset, const float);
	if (values[0] != (float)sequence || values[1] != -(float)sequence) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		progress_write_end(&data->command_progress_sequence);
		fail(data, "processing graph output did not preserve the primary Float32 payload");
		return;
	}
	atomic_store_explicit(&data->last_command_sequence, sequence,
		memory_order_seq_cst);
	if (!increment_counter(&data->commands_received, &commands)) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		progress_write_end(&data->command_progress_sequence);
		fail(data, "processing graph command counter overflowed");
		return;
	}
	progress_write_end(&data->command_progress_sequence);
	(void)pw_stream_queue_buffer(data->command_sink, buffer);
}

static void source_add_buffer(void *userdata, struct pw_buffer *buffer)
{
	struct fixture *data = userdata;
	uint32_t count;

	(void)buffer;
	if (!increment_counter(&data->source_buffers_added, &count))
		fail(data, "slow source add-buffer counter overflowed");
}

static void source_remove_buffer(void *userdata, struct pw_buffer *buffer)
{
	struct fixture *data = userdata;
	uint32_t count;

	(void)buffer;
	if (!increment_counter(&data->source_buffers_removed, &count))
		fail(data, "slow source remove-buffer counter overflowed");
}

static void sink_add_buffer(void *userdata, struct pw_buffer *buffer)
{
	struct fixture *data = userdata;
	uint32_t count;

	(void)buffer;
	if (!increment_counter(&data->observer_buffers_added, &count))
		fail(data, "hold observer add-buffer counter overflowed");
}

static void sink_remove_buffer(void *userdata, struct pw_buffer *buffer)
{
	struct fixture *data = userdata;
	uint32_t count;

	(void)buffer;
	if (!increment_counter(&data->observer_buffers_removed, &count))
		fail(data, "hold observer remove-buffer counter overflowed");
}

static void source_state_changed(void *userdata, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct fixture *data = userdata;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR) {
		fprintf(stderr, "slow source state error: %s\n",
			error == NULL ? "unknown" : error);
		fail(data, "slow source entered an error state");
	}
}

static void primary_state_changed(void *userdata, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct fixture *data = userdata;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR) {
		fprintf(stderr, "primary source state error: %s\n",
			error == NULL ? "unknown" : error);
		fail(data, "primary source entered an error state");
	}
}

static void sink_state_changed(void *userdata, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct fixture *data = userdata;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR) {
		fprintf(stderr, "hold sink state error: %s\n",
			error == NULL ? "unknown" : error);
		fail(data, "hold sink entered an error state");
	}
}

static void command_sink_state_changed(void *userdata,
		enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct fixture *data = userdata;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR) {
		fprintf(stderr, "command sink state error: %s\n",
			error == NULL ? "unknown" : error);
		fail(data, "native FGN command sink entered an error state");
	}
}

static const struct pw_stream_events source_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = source_state_changed,
	.add_buffer = source_add_buffer,
	.remove_buffer = source_remove_buffer,
	.process = source_process,
};

static const struct pw_stream_events primary_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = primary_state_changed,
	.process = primary_process,
};

static const struct pw_stream_events sink_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = sink_state_changed,
	.add_buffer = sink_add_buffer,
	.remove_buffer = sink_remove_buffer,
	.process = sink_process,
};

static const struct pw_stream_events command_sink_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = command_sink_state_changed,
	.process = command_sink_process,
};

static void print_progress(const struct fixture *data)
{
	uint32_t source_sequence, primary_sequence, sink_sequence, command_sequence;
	uint32_t cycles, primary, published, empty, received, commands;
	uint32_t rate_num, rate_denom, quantum, gaps, offered_cycle, offered_primary;
	uint64_t first, last, held_last;
	unsigned int attempt;

	for (attempt = 0; attempt < 1000u; attempt++) {
		if (!progress_read_begin(&data->source_progress_sequence,
				&source_sequence))
			continue;
		cycles = atomic_load_explicit(&data->source_cycles, memory_order_seq_cst);
		published = atomic_load_explicit(&data->source_published,
			memory_order_seq_cst);
		empty = atomic_load_explicit(&data->source_empty, memory_order_seq_cst);
		offered_cycle = atomic_load_explicit(&data->input_data_cycle,
			memory_order_seq_cst);
		offered_primary = atomic_load_explicit(&data->input_primary_sequence,
			memory_order_seq_cst);
		if (progress_read_end(&data->source_progress_sequence, source_sequence))
			break;
	}
	if (attempt == 1000u)
		return;
	for (attempt = 0; attempt < 1000u; attempt++) {
		if (!progress_read_begin(&data->primary_progress_sequence,
				&primary_sequence))
			continue;
		primary = atomic_load_explicit(&data->primary_cycles, memory_order_seq_cst);
		rate_num = atomic_load_explicit(&data->primary_rate_num, memory_order_seq_cst);
		rate_denom = atomic_load_explicit(&data->primary_rate_denom, memory_order_seq_cst);
		quantum = atomic_load_explicit(&data->primary_quantum, memory_order_seq_cst);
		if (progress_read_end(&data->primary_progress_sequence, primary_sequence))
			break;
	}
	if (attempt == 1000u)
		return;
	for (attempt = 0; attempt < 1000u; attempt++) {
		if (!progress_read_begin(&data->sink_progress_sequence, &sink_sequence))
			continue;
		received = atomic_load_explicit(&data->sink_received, memory_order_seq_cst);
		held_last = atomic_load_explicit(&data->last_header_sequence,
			memory_order_seq_cst);
		if (progress_read_end(&data->sink_progress_sequence, sink_sequence))
			break;
	}
	if (attempt == 1000u)
		return;
	for (attempt = 0; attempt < 1000u; attempt++) {
		if (!progress_read_begin(&data->command_progress_sequence,
				&command_sequence))
			continue;
		commands = atomic_load_explicit(&data->commands_received, memory_order_seq_cst);
		first = atomic_load_explicit(&data->first_command_sequence,
			memory_order_seq_cst);
		last = atomic_load_explicit(&data->last_command_sequence, memory_order_seq_cst);
		gaps = atomic_load_explicit(&data->command_gaps, memory_order_seq_cst);
		if (progress_read_end(&data->command_progress_sequence, command_sequence))
			break;
	}
	if (attempt == 1000u)
		return;

	printf("PROGRESS cycles=%u primary=%u data=%u empty=%u received=%u commands=%u first=%" PRIuFAST64 " last=%" PRIuFAST64 " rate=%u/%u quantum=%u gaps=%u offered_cycle=%u offered_primary=%u held_last=%" PRIuFAST64 " source_added=%u source_removed=%u observer_added=%u observer_removed=%u\n",
		cycles, primary, published, empty, received, commands, first, last,
		rate_num, rate_denom, quantum, gaps,
		offered_cycle,
		offered_primary,
		held_last,
		atomic_load_explicit(&data->source_buffers_added, memory_order_acquire),
		atomic_load_explicit(&data->source_buffers_removed, memory_order_acquire),
		atomic_load_explicit(&data->observer_buffers_added, memory_order_acquire),
		atomic_load_explicit(&data->observer_buffers_removed, memory_order_acquire));
	fflush(stdout);
}

static void control(void *userdata, int fd, uint32_t mask)
{
	struct fixture *data = userdata;
	char command;

	if ((mask & SPA_IO_IN) == 0 || read(fd, &command, sizeof(command)) !=
			(ssize_t)sizeof(command)) {
		fail(data, "slow-source control channel failed");
		return;
	}
	if (command == 'a') {
		if (atomic_exchange_explicit(&data->active, true, memory_order_acq_rel) ||
			pw_stream_set_active(data->source, true) < 0 ||
			pw_stream_set_active(data->primary_source, true) < 0) {
			fail(data, "slow source could not activate exactly once");
			return;
		}
		printf("ACTIVE\n");
		fflush(stdout);
	} else if (command == 's') {
		if (!atomic_load_explicit(&data->active, memory_order_acquire) ||
			atomic_exchange_explicit(&data->started, true, memory_order_acq_rel)) {
			fail(data, "slow source could not begin publishing exactly once");
			return;
		}
		printf("STARTED\n");
		fflush(stdout);
	} else if (command == 'n') {
		uint32_t published = atomic_load_explicit(&data->source_published,
			memory_order_acquire);
		uint32_t requests = atomic_load_explicit(&data->extra_requests,
			memory_order_acquire);

		if (requests >= EXTRA_SAMPLES || published != SAMPLES + requests ||
			atomic_load_explicit(&data->next_sample_enabled, memory_order_acquire)) {
			fail(data, "slow source could not enable exactly one next sample");
			return;
		}
		atomic_store_explicit(&data->extra_requests, requests + 1u,
			memory_order_release);
		atomic_store_explicit(&data->next_sample_enabled, true, memory_order_release);
		printf("NEXT_SAMPLE_ENABLED identity=%u\n", published + 1u);
		fflush(stdout);
	} else if (command == 'g') {
		if (atomic_load_explicit(&data->command_gaps, memory_order_acquire) >= 2u ||
			atomic_exchange_explicit(&data->command_gap_armed, true,
				memory_order_acq_rel))
			fail(data, "processing graph command gap was already armed");
	} else if (command == 'r') {
		printf("SESSION_RESTART_MARKER cycle=%u\n",
			atomic_load_explicit(&data->source_cycles, memory_order_seq_cst));
		fflush(stdout);
	} else if (command == 't') {
		printf("GROUP_RESTART_MARKER cycle=%u\n",
			atomic_load_explicit(&data->source_cycles, memory_order_seq_cst));
		fflush(stdout);
	} else if (command == 'u') {
		if (!update_stream_format(data, data->source, SLOW_RATE, SLOW_SCHEMA,
				"slow source"))
			return;
		printf("SLOW_SOURCE_POOL_UPDATE_REQUESTED\n");
		fflush(stdout);
	} else if (command == 'v') {
		if (!update_stream_format(data, data->sink, FAST_RATE, SLOW_SCHEMA,
				"hold observer"))
			return;
		printf("HOLD_OBSERVER_POOL_UPDATE_REQUESTED\n");
		fflush(stdout);
	} else if (command == 'p') {
		print_progress(data);
	} else if (command == 'q') {
		print_progress(data);
		pw_main_loop_quit(data->loop);
	} else {
		fail(data, "unknown slow-source control command");
	}
}

static void destroy_streams(struct fixture *data)
{
	if (data->primary_source != NULL) {
		pw_stream_destroy(data->primary_source);
		data->primary_source = NULL;
	}
	if (data->source != NULL) {
		pw_stream_destroy(data->source);
		data->source = NULL;
	}
	if (data->sink != NULL) {
		pw_stream_destroy(data->sink);
		data->sink = NULL;
	}
	if (data->command_sink != NULL) {
		pw_stream_destroy(data->command_sink);
		data->command_sink = NULL;
	}
}

int main(int argc, char *argv[])
{
	struct fixture data = { 0 };
	struct pw_properties *properties;
	struct spa_pod_builder source_builder, sink_builder;
	struct spa_pod *primary_params[3], *source_params[3], *sink_params[3], *command_params[3];
	uint8_t primary_pods[1024], source_pods[1024], sink_pods[1024], command_pods[1024];
	int result;

	if (argc != 2) {
		fprintf(stderr, "usage: %s REMOTE_NAME\n", argv[0]);
		return 2;
	}
	pw_init(&argc, &argv);
	atomic_init(&data.source_cycles, 0);
	atomic_init(&data.primary_cycles, 0);
	atomic_init(&data.source_published, 0);
	atomic_init(&data.extra_requests, 0);
	atomic_init(&data.source_empty, 0);
	atomic_init(&data.sink_received, 0);
	atomic_init(&data.commands_received, 0);
	atomic_init(&data.input_data_cycle, 0);
	atomic_init(&data.input_primary_sequence, 0);
	atomic_init(&data.last_header_sequence, 0);
	atomic_init(&data.first_command_sequence, 0);
	atomic_init(&data.last_command_sequence, 0);
	atomic_init(&data.command_gaps, 0);
	atomic_init(&data.source_buffers_added, 0);
	atomic_init(&data.source_buffers_removed, 0);
	atomic_init(&data.observer_buffers_added, 0);
	atomic_init(&data.observer_buffers_removed, 0);
	atomic_init(&data.source_progress_sequence, 0);
	atomic_init(&data.primary_progress_sequence, 0);
	atomic_init(&data.sink_progress_sequence, 0);
	atomic_init(&data.command_progress_sequence, 0);
	atomic_init(&data.have_header, false);
	atomic_init(&data.have_command_sequence, false);
	atomic_init(&data.next_sample_enabled, false);
	atomic_init(&data.command_gap_armed, false);
	atomic_init(&data.active, false);
	atomic_init(&data.started, false);
	atomic_init(&data.failed, false);

	data.loop = pw_main_loop_new(NULL);
	if (data.loop == NULL) {
		fprintf(stderr, "could not create source main loop: %s\n", strerror(errno));
		return 1;
	}
	data.context = pw_context_new(pw_main_loop_get_loop(data.loop), NULL, 0);
	if (data.context == NULL) {
		fprintf(stderr, "could not create source context: %s\n", strerror(errno));
		result = 1;
		goto done;
	}
	properties = pw_properties_new(PW_KEY_REMOTE_NAME, argv[1], NULL);
	data.core = pw_context_connect(data.context, properties, 0);
	if (data.core == NULL) {
		fprintf(stderr, "could not connect source core: %s\n", strerror(errno));
		result = 1;
		goto done;
	}
	data.primary_source = pw_stream_new(data.core, "latest-hold primary source",
		pw_properties_new(PW_KEY_NODE_NAME,
			"pipewireao-rtc-latest-hold-primary-source", PW_KEY_NODE_FORCE_RATE,
			"1000", PW_KEY_NODE_FORCE_QUANTUM, "1",
			PW_KEY_NODE_ALWAYS_PROCESS, "true",
			PW_KEY_MEDIA_TYPE, "Application",
			PW_KEY_MEDIA_CATEGORY, "Playback", PW_KEY_MEDIA_ROLE, "Test", NULL));
	data.source = pw_stream_new(data.core, "latest-hold slow source",
		pw_properties_new(PW_KEY_NODE_NAME,
			"pipewireao-rtc-latest-hold-slow-source", PW_KEY_NODE_RATE, "1/100",
			PW_KEY_NODE_ALWAYS_PROCESS, "true", PW_KEY_MEDIA_TYPE,
			"Application", PW_KEY_MEDIA_CATEGORY, "Playback", PW_KEY_MEDIA_ROLE,
			"Test", NULL));
	data.sink = pw_stream_new(data.core, "latest-hold observer",
		pw_properties_new(PW_KEY_NODE_NAME, "pipewireao-rtc-latest-hold-observer",
			PW_KEY_MEDIA_TYPE, "Application", PW_KEY_MEDIA_CATEGORY, "Capture",
			PW_KEY_MEDIA_ROLE, "Test", NULL));
	data.command_sink = pw_stream_new(data.core, "latest-hold command sink",
		pw_properties_new(PW_KEY_NODE_NAME,
			"pipewireao-rtc-latest-hold-command-sink", PW_KEY_MEDIA_TYPE,
			"Application", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE,
			"Test", NULL));
	if (data.primary_source == NULL || data.source == NULL || data.sink == NULL ||
		data.command_sink == NULL) {
		fprintf(stderr, "could not create latest-hold fixture streams\n");
		result = 1;
		goto done;
	}
	pw_stream_add_listener(data.source, &data.source_listener, &source_events, &data);
	pw_stream_add_listener(data.primary_source, &data.primary_listener,
		&primary_events, &data);
	pw_stream_add_listener(data.sink, &data.sink_listener, &sink_events, &data);
	pw_stream_add_listener(data.command_sink, &data.command_listener,
		&command_sink_events, &data);
	spa_pod_builder_init(&source_builder, primary_pods, sizeof(primary_pods));
	primary_params[0] = build_format(&source_builder, FAST_RATE,
		PRIMARY_SCHEMA);
	primary_params[1] = build_header_meta(&source_builder);
	primary_params[2] = build_acquisition_meta(&source_builder);
	spa_pod_builder_init(&source_builder, source_pods, sizeof(source_pods));
	source_params[0] = build_format(&source_builder, SLOW_RATE,
		SLOW_SCHEMA);
	source_params[1] = build_header_meta(&source_builder);
	source_params[2] = build_acquisition_meta(&source_builder);
	spa_pod_builder_init(&sink_builder, sink_pods, sizeof(sink_pods));
	sink_params[0] = build_format(&sink_builder, FAST_RATE,
		SLOW_SCHEMA);
	sink_params[1] = build_header_meta(&sink_builder);
	sink_params[2] = build_acquisition_meta(&sink_builder);
	spa_pod_builder_init(&source_builder, command_pods, sizeof(command_pods));
	command_params[0] = build_format(&source_builder, FAST_RATE,
		PRIMARY_SCHEMA);
	command_params[1] = build_header_meta(&source_builder);
	command_params[2] = build_acquisition_meta(&source_builder);
	if (primary_params[0] == NULL || primary_params[1] == NULL ||
		primary_params[2] == NULL || source_params[0] == NULL || source_params[1] == NULL ||
		source_params[2] == NULL || sink_params[0] == NULL ||
		sink_params[1] == NULL || sink_params[2] == NULL ||
		command_params[0] == NULL || command_params[1] == NULL ||
		command_params[2] == NULL) {
		fprintf(stderr, "could not build latest-hold fixture parameters\n");
		result = 1;
		goto done;
	}
	result = pw_stream_connect(data.primary_source, PW_DIRECTION_OUTPUT, PW_ID_ANY,
		PW_STREAM_FLAG_INACTIVE | PW_STREAM_FLAG_MAP_BUFFERS |
		PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_NO_CONVERT,
		(const struct spa_pod **)primary_params, SPA_N_ELEMENTS(primary_params));
	if (result >= 0)
		result = pw_stream_connect(data.source, PW_DIRECTION_OUTPUT, PW_ID_ANY,
		PW_STREAM_FLAG_INACTIVE | PW_STREAM_FLAG_MAP_BUFFERS |
		PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_NO_CONVERT,
		(const struct spa_pod **)source_params, SPA_N_ELEMENTS(source_params));
	if (result >= 0)
		result = pw_stream_connect(data.sink, PW_DIRECTION_INPUT, PW_ID_ANY,
			PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS |
			PW_STREAM_FLAG_NO_CONVERT, (const struct spa_pod **)sink_params,
			SPA_N_ELEMENTS(sink_params));
	if (result >= 0)
		result = pw_stream_connect(data.command_sink, PW_DIRECTION_INPUT,
			PW_ID_ANY, PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS |
			PW_STREAM_FLAG_NO_CONVERT, (const struct spa_pod **)command_params,
			SPA_N_ELEMENTS(command_params));
	if (result < 0) {
		fprintf(stderr, "could not connect latest-hold fixture streams: %s\n",
			spa_strerror(result));
		result = 1;
		goto done;
	}
	data.control = pw_loop_add_io(pw_main_loop_get_loop(data.loop), STDIN_FILENO,
		SPA_IO_IN | SPA_IO_HUP | SPA_IO_ERR, false, control, &data);
	if (data.control == NULL) {
		fprintf(stderr, "could not create slow-source control channel: %s\n",
			strerror(errno));
		result = 1;
		goto done;
	}
	printf("READY\n");
	fflush(stdout);
	pw_main_loop_run(data.loop);
	/* pw_stream_destroy synchronously removes each process callback before the
	 * terminal counter relationships are checked below. */
	destroy_streams(&data);
	result = atomic_load_explicit(&data.failed, memory_order_acquire) ? 1 : 0;
	if (result == 0 &&
		atomic_load_explicit(&data.extra_requests, memory_order_acquire) == 0u &&
		(!atomic_load_explicit(&data.started, memory_order_acquire) ||
		 atomic_load_explicit(&data.source_cycles, memory_order_acquire) < EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.primary_cycles, memory_order_acquire) < EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.source_published, memory_order_acquire) != SAMPLES ||
		 atomic_load_explicit(&data.source_empty, memory_order_acquire) + SAMPLES !=
			atomic_load_explicit(&data.source_cycles, memory_order_acquire) ||
		 atomic_load_explicit(&data.sink_received, memory_order_acquire) !=
			INITIAL_HELD_OUTPUTS ||
		 atomic_load_explicit(&data.command_gaps, memory_order_acquire) != 0u ||
		 atomic_load_explicit(&data.command_gap_armed, memory_order_acquire) ||
		 atomic_load_explicit(&data.commands_received, memory_order_acquire) == 0)) {
		fprintf(stderr, "latest-hold fixture did not prove cadence, expiry, or no backlog\n");
		result = 1;
	}
	if (result == 0 &&
		atomic_load_explicit(&data.extra_requests, memory_order_acquire) == EXTRA_SAMPLES &&
		(!atomic_load_explicit(&data.started, memory_order_acquire) ||
		 atomic_load_explicit(&data.source_cycles, memory_order_acquire) <
			EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.primary_cycles, memory_order_acquire) <
			EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.source_published, memory_order_acquire) !=
			TOTAL_SAMPLES ||
		 atomic_load_explicit(&data.source_empty, memory_order_acquire) +
			TOTAL_SAMPLES !=
			atomic_load_explicit(&data.source_cycles, memory_order_acquire) ||
		 atomic_load_explicit(&data.sink_received, memory_order_acquire) !=
			FULL_HELD_OUTPUTS ||
		 atomic_load_explicit(&data.command_gap_armed, memory_order_acquire) ||
		 atomic_load_explicit(&data.commands_received, memory_order_acquire) == 0)) {
		fprintf(stderr, "latest-hold fixture did not prove the full restart identity run\n");
		result = 1;
	}
	if (result == 0 && atomic_load_explicit(&data.extra_requests,
			memory_order_acquire) != 0u &&
		atomic_load_explicit(&data.extra_requests, memory_order_acquire) != EXTRA_SAMPLES) {
		fprintf(stderr, "latest-hold fixture ended with a partial restart identity run\n");
		result = 1;
	}

done:
	destroy_streams(&data);
	if (data.core != NULL)
		pw_core_disconnect(data.core);
	if (data.context != NULL)
		pw_context_destroy(data.context);
	if (data.loop != NULL)
		pw_main_loop_destroy(data.loop);
	pw_deinit();
	return result;
}
