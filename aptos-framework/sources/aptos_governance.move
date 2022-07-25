/**
 * AptosGovernance represents the on-chain governance of the Aptos network. Voting power is calculated based on the
 * current epoch's voting power of the proposer or voter's backing stake pool. In addition, for it to count,
 * the stake pool's lockup needs to be at least as long as the proposal's duration.
 *
 * It provides the following flow:
 * 1. Proposers can create a proposal by calling AptosGovernance::create_proposal. The proposer's backing stake pool
 * needs to have the minimum proposer stake required. Off-chain components can subscribe to CreateProposalEvent to
 * track proposal creation and proposal ids.
 * 2. Voters can vote on a proposal. Their voting power is derived from the backing stake pool. Each stake pool can
 * only be used to vote on each proposal exactly once.
 *
 */
module aptos_framework::aptos_governance {
    use std::error;
    use aptos_std::event::{Self, EventHandle};
    use std::option;
    use std::signer;
    use std::string::utf8;

    use aptos_framework::account::{SignerCapability, create_signer_with_capability};
    use aptos_framework::coin;
    use aptos_framework::governance_proposal::{Self, GovernanceProposal};
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::system_addresses;
    use aptos_std::table::{Self, Table};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::voting;

    /// Error codes.
    const EINSUFFICIENT_PROPOSER_STAKE: u64 = 1;
    const ENOT_DELEGATED_VOTER: u64 = 2;
    const EINSUFFICIENT_STAKE_LOCKUP: u64 = 3;
    const EALREADY_VOTED: u64 = 4;
    const ENO_VOTING_POWER: u64 = 5;

    /// Store the SignerCapability of the framework account (0x1) so AptosGovernance can have control over it.
    struct GovernanceResponsbility has key {
        signer_cap: SignerCapability,
    }

    /// Configurations of the AptosGovernance, set during Genesis and can be updated by the same process offered
    /// by this AptosGovernance module.
    struct GovernanceConfig has key {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_period_secs: u64,
    }

    struct RecordKey has copy, drop, store {
        stake_pool: address,
        proposal_id: u64,
    }

    /// Records to track the proposals each stake pool has been used to vote on.
    struct VotingRecords has key {
        votes: Table<RecordKey, bool>
    }

    /// Events generated by interactions with the AptosGovernance module.
    struct GovernanceEvents has key {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        update_config_events: EventHandle<UpdateConfigEvent>,
        vote_events: EventHandle<VoteEvent>,
    }

    /// Event emitted when a proposal is created.
    struct CreateProposalEvent has drop, store {
        proposer: address,
        stake_pool: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    }

    /// Event emitted when there's a vote on a proposa;
    struct VoteEvent has drop, store {
        proposal_id: u64,
        voter: address,
        stake_pool: address,
        num_votes: u64,
        should_pass: bool,
    }

    /// Event emitted when the governance configs are updated.
    struct UpdateConfigEvent has drop, store {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_period_secs: u64,
    }

    /// Stores the signer capability for 0x1.
    public fun store_signer_cap(
        aptos_framework: &signer,
        signer_cap: SignerCapability,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        move_to(aptos_framework, GovernanceResponsbility { signer_cap });
    }

    /// Initializes the state for Aptos Governance. Can only be called during Genesis with a signer
    /// for the aptos_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_period_secs: u64,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);

        voting::register<GovernanceProposal>(aptos_framework);
        move_to(aptos_framework, GovernanceConfig {
            voting_period_secs,
            min_voting_threshold,
            required_proposer_stake,
        });
        move_to(aptos_framework, GovernanceEvents {
            create_proposal_events: event::new_event_handle<CreateProposalEvent>(aptos_framework),
            update_config_events: event::new_event_handle<UpdateConfigEvent>(aptos_framework),
            vote_events: event::new_event_handle<VoteEvent>(aptos_framework),
        });
        move_to(aptos_framework, VotingRecords {
            votes: table::new(),
        });
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// AptosGovernance.
    public fun update_governance_config(
        _proposal: GovernanceProposal,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_period_secs: u64,
    ) acquires GovernanceConfig, GovernanceEvents {
        let governance_config = borrow_global_mut<GovernanceConfig>(@aptos_framework);
        governance_config.voting_period_secs = voting_period_secs;
        governance_config.min_voting_threshold = min_voting_threshold;
        governance_config.required_proposer_stake = required_proposer_stake;

        let events = borrow_global_mut<GovernanceEvents>(@aptos_framework);
        event::emit_event<UpdateConfigEvent>(
            &mut events.update_config_events,
            UpdateConfigEvent {
                min_voting_threshold,
                required_proposer_stake,
                voting_period_secs
            },
        );
    }

    /// Create a proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    ): u64 acquires GovernanceConfig, GovernanceEvents {
        let proposer_address = signer::address_of(proposer);
        assert!(stake::get_delegated_voter(stake_pool) == proposer_address, error::invalid_argument(ENOT_DELEGATED_VOTER));

        // The proposer's stake needs to be at least the required bond amount.
        let governance_config = borrow_global<GovernanceConfig>(@aptos_framework);
        let stake_balance = stake::get_active_staked_balance(stake_pool);
        assert!(
            stake_balance >= governance_config.required_proposer_stake,
            error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE),
        );

        // The proposer's stake needs to be locked up at least as long as the proposal's voting period.
        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + governance_config.voting_period_secs;
        assert!(
            stake::get_lockup_secs(stake_pool) >= proposal_expiration,
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );

        // We want to allow early resolution of proposals if more than 50% of the total supply of the network coins
        // has voted. This doesn't take into subsequent inflation/deflation (rewards are issued every epoch and gas fees
        // are burnt after every transaction), but inflation/delation is very unlikely to have a major impact on total
        // supply during the voting period.
        let total_voting_token_supply = coin::supply<AptosCoin>();
        let early_resolution_vote_threshold = option::none<u128>();
        if (option::is_some(&total_voting_token_supply)) {
            let total_supply = *option::borrow(&total_voting_token_supply);
            // 50% + 1 to avoid rounding errors.
            early_resolution_vote_threshold = option::some(total_supply / 2 + 1);
        };

        let proposal_id = voting::create_proposal(
            proposer_address,
            @aptos_framework,
            governance_proposal::create_proposal(
                utf8(metadata_location),
                utf8(metadata_hash),
            ),
            execution_hash,
            governance_config.min_voting_threshold,
            proposal_expiration,
            early_resolution_vote_threshold,
        );

        let events = borrow_global_mut<GovernanceEvents>(@aptos_framework);
        event::emit_event<CreateProposalEvent>(
            &mut events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                proposer: proposer_address,
                stake_pool,
                execution_hash,
                metadata_location,
                metadata_hash,
            },
        );

        proposal_id
    }

    /// Vote on proposal with `proposal_id` and voting power from `stake_pool`.
    public entry fun vote(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        should_pass: bool,
    ) acquires GovernanceEvents, VotingRecords {
        let voter_address = signer::address_of(voter);
        assert!(stake::get_delegated_voter(stake_pool) == voter_address, error::invalid_argument(ENOT_DELEGATED_VOTER));

        // Voting power does not include pending_active or pending_inactive balances.
        // In general, the stake pool should not have pending_inactive balance if it still has lockup (required to vote)
        // And if pending_active will be added to active in the next epoch.
        let voting_power = stake::get_active_staked_balance(stake_pool);
        // Short-circuit if the voter has no voting power.
        assert!(voting_power > 0, error::invalid_argument(ENO_VOTING_POWER));

        // The voter's stake needs to be locked up at least as long as the proposal's expiration.
        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(@aptos_framework, proposal_id);
        assert!(
            stake::get_lockup_secs(stake_pool) >= proposal_expiration,
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );

        // Ensure the voter doesn't double vote.
        let voting_records = borrow_global_mut<VotingRecords>(@aptos_framework);
        let record_key = RecordKey {
            stake_pool,
            proposal_id,
        };
        assert!(
            !table::contains(&voting_records.votes, record_key),
            error::invalid_argument(EALREADY_VOTED));
        table::add(&mut voting_records.votes, record_key, true);

        voting::vote<GovernanceProposal>(
            &governance_proposal::create_empty_proposal(),
            @aptos_framework,
            proposal_id,
            voting_power,
            should_pass,
        );

        let events = borrow_global_mut<GovernanceEvents>(@aptos_framework);
        event::emit_event<VoteEvent>(
            &mut events.vote_events,
            VoteEvent {
                proposal_id,
                voter: voter_address,
                stake_pool,
                num_votes: voting_power,
                should_pass,
            },
        );
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    public fun get_framework_signer(_proposal: GovernanceProposal): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@aptos_framework);
        create_signer_with_capability(&governance_responsibility.signer_cap)
    }

    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun reconfigure(_proposal: &GovernanceProposal) {
        reconfiguration::reconfigure();
    }

    #[test(core_resources = @core_resources, aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        core_resources: signer,
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires GovernanceConfig, GovernanceEvents, VotingRecords {
        setup_voting(
            &core_resources,
            &aptos_framework,
            &proposer,
            &yes_voter,
            &no_voter,
        );

        let proposal_id = create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"123",
            b"",
            b"",
        );
        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(signer::address_of(&aptos_framework), proposal_id);
        assert!(proposal_state == 1, proposal_state);
    }

    #[test(core_resources = @core_resources, aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_cannot_double_vote(
        core_resources: signer,
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceEvents, VotingRecords {
        setup_voting(
            &core_resources,
            &aptos_framework,
            &proposer,
            &voter_1,
            &voter_2,
        );

        let proposal_id = create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"",
            b"",
            b"",
        );

        // Double voting should throw an error.
        vote(&voter_1, signer::address_of(&voter_1), proposal_id, true);
        vote(&voter_1, signer::address_of(&voter_1), proposal_id, true);
    }

    #[test(core_resources = @core_resources, aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_cannot_double_vote_with_different_voter_addresses(
        core_resources: signer,
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceEvents, VotingRecords {
        setup_voting(
            &core_resources,
            &aptos_framework,
            &proposer,
            &voter_1,
            &voter_2,
        );

        let proposal_id = create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"",
            b"",
            b"",
        );

        // Double voting should throw an error for 2 different voters if they still use the same stake pool.
        vote(&voter_1, signer::address_of(&voter_1), proposal_id, true);
        stake::set_delegated_voter(&voter_1, signer::address_of(&voter_2));
        vote(&voter_2, signer::address_of(&voter_1), proposal_id, true);
    }

    #[test_only]
    fun setup_voting(
        core_resources: &signer,
        aptos_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) {
        use std::vector;
        use aptos_framework::coin;
        use aptos_framework::aptos_coin::{Self, AptosCoin};

        timestamp::set_time_has_started_for_testing(aptos_framework);

        // Initialize the governance.
        initialize(aptos_framework, 10, 100, 1000);

        // Initialize the stake pools for proposer and voters.
        let active_validators = vector::empty<address>();
        vector::push_back(&mut active_validators, signer::address_of(proposer));
        vector::push_back(&mut active_validators, signer::address_of(yes_voter));
        vector::push_back(&mut active_validators, signer::address_of(no_voter));
        stake::create_validator_set(aptos_framework, active_validators);

        let (mint_cap, burn_cap) = aptos_coin::initialize(aptos_framework, core_resources);
        let proposer_stake = coin::mint(100, &mint_cap);
        let yes_voter_stake = coin::mint(20, &mint_cap);
        let no_voter_stake = coin::mint(10, &mint_cap);
        stake::create_stake_pool(proposer, proposer_stake, 10000);
        stake::create_stake_pool(yes_voter, yes_voter_stake, 10000);
        stake::create_stake_pool(no_voter, no_voter_stake, 10000);
        coin::destroy_mint_cap<AptosCoin>(mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
    }
}
