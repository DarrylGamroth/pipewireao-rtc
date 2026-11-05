# Included inside CorrectionRecovery. Plural scopes retain one global recovery
# transaction and exact independent controller adoption generations.
selected_controllers(scope::Tuple, ::Nothing) = scope
selected_controllers(scope::Tuple, selection) = throw(
    ArgumentError("resume requires a nonempty bounded collection of controller names"),
)
function selected_controllers(
    scope::Tuple,
    selection::Union{Tuple{Vararg{AbstractString}},AbstractVector{<:AbstractString}},
)
    1 <= length(selection) <= length(scope) || throw(
        ArgumentError("resume requires a nonempty bounded collection of controller names"),
    )
    names = Tuple(String.(selection))
    allunique(names) && all(in(scope), names) ||
        throw(ArgumentError("resume selection must contain distinct scoped controllers"))
    return names
end

function fresh_controllers(
    operation::Operation,
    snapshot::RecoverySnapshot,
    selected,
    after_sequence,
)
    now = transport_clock_ns(operation.channel.transport)
    timeout = min(operation.reference_timeout_ns, snapshot.reference_timeout_ns)
    return all(eachindex(selected)) do index
        selected[index] || return true
        proof = controller_readbacks(snapshot)[index].readiness
        proof.guarded &&
            proof.ready &&
            proof.sequence > after_sequence &&
            proof.timestamp_ns > 0 &&
            now >= proof.timestamp_ns &&
            now - proof.timestamp_ns < timeout
    end
end

function require_controller_values(operation, snapshot, target)
    closed(snapshot) == target &&
    generations_match(snapshot) &&
    requested_generation(snapshot) == operation.coordinator.loop_generation || throw(
        ControlClient.UnknownOutcome("coupled controller state or generation changed"),
    )
    adoption_matches(snapshot) ||
        throw(ControlClient.UnknownOutcome("coupled controller adoption is not coherent"))
    return nothing
end

function require_released(operation, snapshot, virtual_generation)
    require_scope(operation, snapshot)
    snapshot.recovery_state === :released &&
    !snapshot.inhibited &&
    snapshot.release_token == operation.coordinator.recovery_generation &&
    snapshot.requested_generation == snapshot.active_generation == virtual_generation ||
        throw(ControlClient.UnknownOutcome("coupled recovery release changed"))
    return nothing
end

release_for_close!(
    operation::Operation,
    close::CloseLoop,
    before::RecoverySnapshot,
    pending;
    deadline::Float64,
    check,
) = (close, before.requested_generation)

function release_for_close!(
    operation::Operation,
    release::ReleaseRecovery,
    before::RecoverySnapshot,
    pending;
    deadline::Float64,
    check,
)
    coordinator = operation.coordinator
    reply = write_property!(
        operation,
        RECOVERY_PREFIX * "release-token",
        RecoveryRunner.RunnerScalar(:long, Int64(release.generation));
        deadline,
        check,
    )
    virtual_generation = generation_for(reply, RECOVERY_NODE)
    virtual_generation > before.requested_generation ||
        throw(ArgumentError("release transaction did not advance"))
    while state(coordinator) === :Releasing
        snapshot = snapshot!(operation; deadline, check)
        require_controller_values(
            operation,
            snapshot,
            open_target(controller_scope(coordinator)),
        )
        require_scope(operation, snapshot)
        snapshot.requested_generation == virtual_generation &&
        snapshot.active_generation <= virtual_generation ||
            throw(ControlClient.UnknownOutcome("release transaction generation changed"))
        if snapshot.recovery_state === :released &&
           snapshot.active_generation == virtual_generation
            require_released(operation, snapshot, virtual_generation)
            if fresh_reference(operation, snapshot, before.source_sequence) &&
               fresh_controllers(operation, snapshot, pending, before.source_sequence)
                close = observe_release!(
                    coordinator,
                    ReleaseObservation(
                        snapshot.owner_instance,
                        coordinator.token,
                        snapshot.serial,
                        snapshot.recovery_generation,
                        true,
                        closed(snapshot),
                        true,
                        true,
                        true,
                    ),
                )
                close === nothing &&
                    throw(ControlClient.UnknownOutcome("release prerequisites changed"))
                return close, virtual_generation
            end
        end
        pause_control!(operation; deadline, check)
    end
    throw(ControlClient.UnknownOutcome("close is not authorized"))
end

function resume_controllers!(operation::Operation; deadline::Float64, check, controllers)
    coordinator = operation.coordinator
    coordinator.failure === nothing && state(coordinator) in (:Holding, :PartiallyClosed) ||
        throw(
            ArgumentError("resume requires verified Holding or a partially reclosed scope"),
        )
    names = selected_controllers(operation.controller, controllers)
    selected = map(name -> name in names, operation.controller)
    pending =
        map((selected, closed) -> selected && !closed, selected, coordinator.target_closed)
    any(pending) || throw(ArgumentError("selected controllers are already closed"))
    target = map(|, coordinator.target_closed, selected)
    first_close = state(coordinator) === :Holding
    try
        running!(operation.channel; deadline, check)
        started = transport_clock_ns(operation.channel.transport)
        before = snapshot!(operation; deadline, check)
        while true
            require_scope(operation, before)
            require_controller_values(operation, before, coordinator.target_closed)
            if first_close
                before.recovery_state === :applied && before.inhibited ||
                    throw(ControlClient.UnknownOutcome("held recovery inhibition changed"))
            else
                require_released(operation, before, before.requested_generation)
            end
            reference =
                !first_close ||
                fresh_reference(operation, before, operation.reference_sequence)
            reference &&
                fresh_controllers(
                    operation,
                    before,
                    pending,
                    operation.reference_sequence,
                ) &&
                break
            transport_clock_ns(operation.channel.transport) - started <
            coordinator.timeout_ns || throw(
                ControlClient.UnknownOutcome(
                    "fresh selected-controller proof did not arrive",
                ),
            )
            pause_control!(operation; deadline, check)
            before = snapshot!(operation; deadline, check)
        end
        observe_reference!(
            coordinator,
            ReferenceObservation(
                before.owner_instance,
                coordinator.token,
                before.serial,
                before.recovery_generation,
                true,
                true,
                true,
            ),
        )
        effect = request_close!(
            coordinator,
            before.owner_instance,
            coordinator.token;
            closed = target,
            released = !first_close,
        )
        effect, virtual_generation =
            release_for_close!(operation, effect, before, pending; deadline, check)
        changes = Dict{String,RecoveryRunner.RunnerScalar}(
            operation.controller[index] * ":closed" =>
                RecoveryRunner.RunnerScalar(:bool, true) for
            index in eachindex(pending) if pending[index]
        )
        reply = write_properties!(operation, changes; deadline, check)
        generations = map(
            pending,
            operation.controller,
            coordinator.loop_generation,
        ) do pending, name, active
            pending ? generation_for(reply, name) : active
        end
        staged!(coordinator, effect, generations)
        while state(coordinator) === :Closing
            snapshot = snapshot!(operation; deadline, check)
            require_released(operation, snapshot, virtual_generation)
            observe_loop!(coordinator, snapshot)
            if state(coordinator) in (:Closed, :PartiallyClosed)
                operation.reference_sequence = snapshot.source_sequence
                return operation
            end
            pause_control!(operation; deadline, check)
        end
        throw(ControlClient.UnknownOutcome("selected close adoption is unverified"))
    catch error
        throw(recovery_error(operation, error))
    end
end
