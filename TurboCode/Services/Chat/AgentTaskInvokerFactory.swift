/// Builds provider workers from immutable runtime configuration.
///
/// Keeping this factory outside `ModelRuntimeStore` ensures an observable UI
/// object can select policy but cannot construct or retain an executable model.
@MainActor
final class AgentTaskInvokerFactory {
    /// Returns a worker only when the selected profile explicitly enables the
    /// model-facing delegation capability.
    func makeDelegateInvoker(
        configuration: ModelSessionConfiguration?,
        events: ModelSessionEvents
    ) -> ConfiguredAgentTaskInvoker? {
        guard let configuration else { return nil }
        return ModelSessionFactory.makeDelegateInvoker(
            configuration: configuration,
            events: events
        )
    }

    /// `/task` is an explicit application command and therefore remains
    /// available even when the model-facing `delegate_task` tool is hidden.
    func makeIndependentTaskInvoker(
        configuration: ModelSessionConfiguration,
        events: ModelSessionEvents
    ) -> ConfiguredAgentTaskInvoker {
        ModelSessionFactory.makeDelegateInvoker(
            configuration: configuration,
            events: events
        )
    }
}
