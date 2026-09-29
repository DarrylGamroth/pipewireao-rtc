/* SPDX-License-Identifier: MIT */

#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
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
#define HOLD_CYCLES 10u
#define EXPIRY_CHECK_CYCLE 120u

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
	atomic_uint source_empty;
	atomic_uint sink_received;
	atomic_uint commands_received;
	atomic_uint primary_rate_num;
	atomic_uint primary_rate_denom;
	atomic_uint primary_quantum;
	atomic_uint_fast64_t last_header_sequence;
	atomic_uint_fast64_t first_command_sequence;
	atomic_uint_fast64_t last_command_sequence;
	atomic_bool have_header;
	atomic_bool have_command_sequence;
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
	cycle = atomic_fetch_add_explicit(&data->source_cycles, 1,
		memory_order_relaxed) + 1u;
	if ((cycle - 1u) % HOLD_CYCLES != 0 ||
		atomic_load_explicit(&data->source_published, memory_order_relaxed) >=
			SAMPLES) {
		/* Deliberately do not dequeue or queue a buffer: the output IO remains
		 * SPA_STATUS_NEED_DATA for this slow-cadence callback. */
		atomic_fetch_add_explicit(&data->source_empty, 1, memory_order_relaxed);
		return;
	}
	buffer = pw_stream_dequeue_buffer(data->source);
	if (buffer == NULL || buffer->buffer == NULL ||
		buffer->buffer->n_datas != 1) {
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
		fail(data, "slow source negotiated incomplete ndarray storage or metadata");
		return;
	}
	sample = atomic_fetch_add_explicit(&data->source_published, 1,
			memory_order_relaxed) + 1u;
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
		fail(data, "slow source could not write Acquisition identity");
		return;
	}
	if (pw_stream_queue_buffer(data->source, buffer) < 0)
		fail(data, "slow source could not publish its sample");
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
	if (pw_stream_get_time_n(data->primary_source, &time, sizeof(time)) == 0) {
		atomic_store_explicit(&data->primary_rate_num, time.rate.num,
			memory_order_relaxed);
		atomic_store_explicit(&data->primary_rate_denom, time.rate.denom,
			memory_order_relaxed);
		atomic_store_explicit(&data->primary_quantum, (uint32_t)time.size,
			memory_order_relaxed);
	}
	buffer = pw_stream_dequeue_buffer(data->primary_source);
	if (buffer == NULL || buffer->buffer == NULL ||
		buffer->buffer->n_datas != 1) {
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
		fail(data, "primary source negotiated incomplete ndarray storage or metadata");
		return;
	}
	sequence = atomic_fetch_add_explicit(&data->primary_cycles, 1,
		memory_order_relaxed) + 1u;
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
		fail(data, "primary source could not write Acquisition identity");
		return;
	}
	if (pw_stream_queue_buffer(data->primary_source, buffer) < 0)
		fail(data, "primary source could not publish its sample");
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
	expected_sample = received / HOLD_CYCLES + 1u;
	if (block->data == NULL || block->chunk == NULL ||
		block->chunk->offset > block->maxsize ||
		block->chunk->size != VECTOR_LENGTH * sizeof(float) ||
		block->maxsize - block->chunk->offset < block->chunk->size ||
		header == NULL || !spa_meta_acquisition_is_valid(meta) ||
		acquisition->generation != 7u || acquisition->sequence != expected_sample ||
		memcmp(acquisition->domain, domain, sizeof(domain)) != 0 ||
		received >= SAMPLES * HOLD_CYCLES) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		fail(data, "hold sink observed an unexpected output or Acquisition identity");
		return;
	}
	sequence = header->seq;
	if (atomic_exchange_explicit(&data->have_header, true, memory_order_acq_rel) &&
		sequence <= atomic_load_explicit(&data->last_header_sequence,
			memory_order_relaxed)) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		fail(data, "hold output Header sequence did not advance");
		return;
	}
	atomic_store_explicit(&data->last_header_sequence, sequence,
		memory_order_relaxed);
	values = SPA_PTROFF(block->data, block->chunk->offset, const float);
	if (values[0] != (float)expected_sample ||
		values[1] != -(float)expected_sample) {
		(void)pw_stream_queue_buffer(data->sink, buffer);
		fail(data, "hold sink observed a payload outside the retained identity run");
		return;
	}
	atomic_fetch_add_explicit(&data->sink_received, 1, memory_order_release);
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
	if (!atomic_exchange_explicit(&data->have_command_sequence, true,
			memory_order_acq_rel)) {
		atomic_store_explicit(&data->first_command_sequence, sequence,
			memory_order_relaxed);
	} else if (sequence != atomic_load_explicit(
			&data->last_command_sequence, memory_order_relaxed) + 1u) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		fail(data, "processing graph output did not advance through contiguous primary identities");
		return;
	}
	values = SPA_PTROFF(block->data, block->chunk->offset, const float);
	if (values[0] != (float)sequence || values[1] != -(float)sequence) {
		(void)pw_stream_queue_buffer(data->command_sink, buffer);
		fail(data, "processing graph output did not preserve the primary Float32 payload");
		return;
	}
	atomic_store_explicit(&data->last_command_sequence, sequence,
		memory_order_relaxed);
	atomic_fetch_add_explicit(&data->commands_received, 1,
		memory_order_release);
	(void)pw_stream_queue_buffer(data->command_sink, buffer);
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
	.process = sink_process,
};

static const struct pw_stream_events command_sink_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = command_sink_state_changed,
	.process = command_sink_process,
};

static void print_progress(const struct fixture *data)
{
	printf("PROGRESS cycles=%u primary=%u data=%u empty=%u received=%u commands=%u first=%" PRIuFAST64 " last=%" PRIuFAST64 " rate=%u/%u quantum=%u\n",
		atomic_load_explicit(&data->source_cycles, memory_order_acquire),
		atomic_load_explicit(&data->primary_cycles, memory_order_acquire),
		atomic_load_explicit(&data->source_published, memory_order_acquire),
		atomic_load_explicit(&data->source_empty, memory_order_acquire),
		atomic_load_explicit(&data->sink_received, memory_order_acquire),
		atomic_load_explicit(&data->commands_received, memory_order_acquire),
		atomic_load_explicit(&data->first_command_sequence, memory_order_acquire),
		atomic_load_explicit(&data->last_command_sequence, memory_order_acquire),
		atomic_load_explicit(&data->primary_rate_num, memory_order_acquire),
		atomic_load_explicit(&data->primary_rate_denom, memory_order_acquire),
		atomic_load_explicit(&data->primary_quantum, memory_order_acquire));
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
	} else if (command == 'p') {
		print_progress(data);
	} else if (command == 'q') {
		print_progress(data);
		pw_main_loop_quit(data->loop);
	} else {
		fail(data, "unknown slow-source control command");
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
	atomic_init(&data.source_empty, 0);
	atomic_init(&data.sink_received, 0);
	atomic_init(&data.commands_received, 0);
	atomic_init(&data.last_header_sequence, 0);
	atomic_init(&data.first_command_sequence, 0);
	atomic_init(&data.last_command_sequence, 0);
	atomic_init(&data.have_header, false);
	atomic_init(&data.have_command_sequence, false);
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
		"org.pipewireao.rtc.latest-hold.primary/1");
	primary_params[1] = build_header_meta(&source_builder);
	primary_params[2] = build_acquisition_meta(&source_builder);
	spa_pod_builder_init(&source_builder, source_pods, sizeof(source_pods));
	source_params[0] = build_format(&source_builder, SLOW_RATE,
		"org.pipewireao.rtc.latest-hold.slow/1");
	source_params[1] = build_header_meta(&source_builder);
	source_params[2] = build_acquisition_meta(&source_builder);
	spa_pod_builder_init(&sink_builder, sink_pods, sizeof(sink_pods));
	sink_params[0] = build_format(&sink_builder, FAST_RATE,
		"org.pipewireao.rtc.latest-hold.slow/1");
	sink_params[1] = build_header_meta(&sink_builder);
	sink_params[2] = build_acquisition_meta(&sink_builder);
	spa_pod_builder_init(&source_builder, command_pods, sizeof(command_pods));
	command_params[0] = build_format(&source_builder, FAST_RATE,
		"org.pipewireao.rtc.latest-hold.primary/1");
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
	result = atomic_load_explicit(&data.failed, memory_order_acquire) ? 1 : 0;
	if (result == 0 &&
		(!atomic_load_explicit(&data.started, memory_order_acquire) ||
		 atomic_load_explicit(&data.source_cycles, memory_order_acquire) < EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.primary_cycles, memory_order_acquire) < EXPIRY_CHECK_CYCLE ||
		 atomic_load_explicit(&data.source_published, memory_order_acquire) != SAMPLES ||
		 atomic_load_explicit(&data.source_empty, memory_order_acquire) + SAMPLES !=
			atomic_load_explicit(&data.source_cycles, memory_order_acquire) ||
		 atomic_load_explicit(&data.sink_received, memory_order_acquire) !=
			SAMPLES * HOLD_CYCLES ||
		 atomic_load_explicit(&data.commands_received, memory_order_acquire) == 0)) {
		fprintf(stderr, "latest-hold fixture did not prove cadence, expiry, or no backlog\n");
		result = 1;
	}

done:
	if (data.primary_source != NULL)
		pw_stream_destroy(data.primary_source);
	if (data.source != NULL)
		pw_stream_destroy(data.source);
	if (data.sink != NULL)
		pw_stream_destroy(data.sink);
	if (data.command_sink != NULL)
		pw_stream_destroy(data.command_sink);
	if (data.core != NULL)
		pw_core_disconnect(data.core);
	if (data.context != NULL)
		pw_context_destroy(data.context);
	if (data.loop != NULL)
		pw_main_loop_destroy(data.loop);
	pw_deinit();
	return result;
}
