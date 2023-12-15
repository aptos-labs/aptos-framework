spec aptos_framework::state_storage {
    /// <high-level-req>
    /// No.: 1
    /// Property: Only the admin address may call the initialization function.
    /// Criticality: Critical
    /// Implementation: The initialize function ensures only the Aptos framework address can call it.
    /// Enforcement: Formally verified via [high-level-req-1](initialize).
    ///
    /// No.: 2
    /// Property: Given the blockchain is in an operating state, the resources for tracking state storage usage and gas
    /// parameters must exist for the Aptos framework address.
    /// Criticality: Critical
    /// Implementation: The initialize function initializes StateStorageUsage for the Aptos framework address.
    /// Enforcement: Formally verified via [high-level-req-2](initialize).
    ///
    /// No.: 3
    /// Property: The initialization function is only called once, during genesis.
    /// Criticality: Medium
    /// Implementation: The initialize function ensures StateStorageUsage does not already exist.
    /// Enforcement: Formally verified via [high-level-req-3](initialize).
    ///
    /// No.: 4
    /// Property: During the initialization of the module, it is guaranteed that the resource for tracking state storage
    /// usage will be moved under the Aptos framework account with default initial values.
    /// Criticality: Medium
    /// Implementation: The resource for tracking state storage usage may only be initialized with specific values and
    /// published under the aptos_framework account.
    /// Enforcement: Formally verified via [high-level-req-4](initialize).
    ///
    /// No.: 5
    /// Property: The structure for tracking state storage usage should exist for it to be updated at the beginning of
    /// each new block and for retrieving the values of structure members.
    /// Criticality: Medium
    /// Implementation: The functions on_new_block and current_items_and_bytes verify that the StateStorageUsage
    /// structure exists before performing any further operations.
    /// Enforcement: Formally Verified via [high-level-req-5.1](current_items_and_bytes), [high-level-req-5.2](on_new_block), and the [high-level-req-5.3](global invariant).
    /// </high-level-req>
    ///
    spec module {
        use aptos_framework::chain_status;
        pragma verify = true;
        pragma aborts_if_is_strict;
        // After genesis, `StateStorageUsage` and `GasParameter` exist.
        /// [high-level-req-5.3]
        invariant [suspendable] chain_status::is_operating() ==> exists<StateStorageUsage>(@aptos_framework);
        invariant [suspendable] chain_status::is_operating() ==> exists<GasParameter>(@aptos_framework);
    }

    /// ensure caller is admin.
    /// aborts if StateStorageUsage already exists.
    spec initialize(aptos_framework: &signer) {
        use std::signer;
        let addr = signer::address_of(aptos_framework);
        /// [high-level-req-1]
        aborts_if !system_addresses::is_aptos_framework_address(addr);
        /// [high-level-req-2]
        aborts_if exists<StateStorageUsage>(@aptos_framework);
        /// [high-level-req-3]
        ensures exists<StateStorageUsage>(@aptos_framework);
        let post state_usage = global<StateStorageUsage>(@aptos_framework);
        /// [high-level-req-4]
        ensures state_usage.epoch == 0 && state_usage.usage.bytes == 0 && state_usage.usage.items == 0;
    }

    spec on_new_block(epoch: u64) {
        use aptos_framework::chain_status;
        /// [high-level-req-5.2]
        requires chain_status::is_operating();
        aborts_if false;
        ensures epoch == global<StateStorageUsage>(@aptos_framework).epoch;
    }

    spec current_items_and_bytes(): (u64, u64) {
        /// [high-level-req-5.1]
        aborts_if !exists<StateStorageUsage>(@aptos_framework);
    }

    spec get_state_storage_usage_only_at_epoch_beginning(): Usage {
        // TODO: temporary mockup.
        pragma opaque;
    }

    spec on_reconfig {
        aborts_if true;
    }
}
