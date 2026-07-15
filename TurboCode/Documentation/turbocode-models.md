# Models and Orchestrator Mode

TurboCode presents one product experience while adapting its profile to the capabilities of the selected model.

In Standalone mode, the active model receives the tools appropriate to its capability tier and handles the request directly. Apple on-device is useful for immediate lightweight assistance and product guidance. Configured local, PCC, or premium models can handle broader coding work according to their declared capabilities.

In Orchestrator mode, Apple on-device interprets the request and coordinates the experience. Navigation and lightweight product questions remain local. Complex inspection, editing, build, test, and Git work is delegated through `call_powerful_model` to the model selected in TurboCode Settings.

The delegated model can be selected under **TurboCode > Settings > Agents > Orchestrator**. Available choices come from `~/.turbocode/models.json`; secrets remain in the macOS Keychain.

TurboCode validates reasoning and tool-calling capabilities before building a model profile. This prevents unsupported options from reaching a model and provides a foundation for giving advanced tools only to models that can use them reliably.
