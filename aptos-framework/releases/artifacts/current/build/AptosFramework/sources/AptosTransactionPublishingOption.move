module AptosFramework::AptosTransactionPublishingOption {
    use Std::Capability;
    use AptosFramework::Marker::{Self, ChainMarker};
    use CoreFramework::DiemTransactionPublishingOption;

    public fun initialize(
        core_resource_account: &signer,
        script_allow_list: vector<vector<u8>>,
        module_publishing_allowed: bool,
    ) {
        DiemTransactionPublishingOption::initialize<ChainMarker>(core_resource_account, script_allow_list, module_publishing_allowed);
    }

    public fun set_module_publishing_allowed(account: &signer, is_allowed: bool) {
        DiemTransactionPublishingOption::set_module_publishing_allowed(is_allowed, Capability::acquire(account, &Marker::get()));
    }
}
