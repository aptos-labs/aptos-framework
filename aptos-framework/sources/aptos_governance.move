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
    use std::option;
    use std::signer;
    use std::string::{Self, String, utf8};

    use aptos_std::event::{Self, EventHandle};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};

    use aptos_framework::account::{SignerCapability, create_signer_with_capability};
    use aptos_framework::coin;
    use aptos_framework::governance_proposal::{Self, GovernanceProposal};
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::system_addresses;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::voting;

    /// The specified stake pool does not have sufficient stake to create a proposal
    const EINSUFFICIENT_PROPOSER_STAKE: u64 = 1;
    /// This account is not the designated voter of the specified stake pool
    const ENOT_DELEGATED_VOTER: u64 = 2;
    /// The specified stake pool does not have long enough remaining lockup to create a proposal or vote
    const EINSUFFICIENT_STAKE_LOCKUP: u64 = 3;
    /// The specified stake pool has already been used to vote on the same proposal
    const EALREADY_VOTED: u64 = 4;
    /// The specified stake pool must be part of the validator set
    const ENO_VOTING_POWER: u64 = 5;
    /// Proposal is not ready to be resolved. Waiting on time or votes
    const EPROPOSAL_NOT_RESOLVABLE_YET: u64 = 6;
    /// Proposal's script hash has already been added to the approved list
    const ESCRIPT_HASH_ALREADY_ADDED: u64 = 7;
    /// The proposal has not been resolved yet
    const EPROPOSAL_NOT_RESOLVED_YET: u64 = 8;
    /// Metadata location cannot be longer than 256 chars
    const EMETADATA_LOCATION_TOO_LONG: u64 = 9;
    /// Metadata hash cannot be longer than 256 chars
    const EMETADATA_HASH_TOO_LONG: u64 = 10;

    /// This matches the same enum const in voting. We have to duplicate it as Move doesn't have support for enums yet.
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

    /// Proposal metadata attribute keys.
    const METADATA_LOCATION_KEY: vector<u8> = b"metadata_location";
    const METADATA_HASH_KEY: vector<u8> = b"metadata_hash";

    /// Store the SignerCapabilities of accounts under the on-chain governance's control.
    struct GovernanceResponsbility has key {
        signer_caps: SimpleMap<address, SignerCapability>,
    }

    /// Configurations of the AptosGovernance, set during Genesis and can be updated by the same process offered
    /// by this AptosGovernance module.
    struct GovernanceConfig has key {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    struct RecordKey has copy, drop, store {
        stake_pool: address,
        proposal_id: u64,
    }

    /// Records to track the proposals each stake pool has been used to vote on.
    struct VotingRecords has key {
        votes: Table<RecordKey, bool>
    }

    /// Used to track which execution script hashes have been approved by governance.
    /// This is required to bypass cases where the execution scripts exceed the size limit imposed by mempool.
    struct ApprovedExecutionHashes has key {
        hashes: SimpleMap<u64, vector<u8>>,
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
        proposal_metadata: SimpleMap<String, vector<u8>>,
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
        voting_duration_secs: u64,
    }

    /// Can be called during genesis or by the governance itself.
    /// Stores the signer capability for a given address.
    public fun store_signer_cap(
        aptos_framework: &signer,
        signer_address: address,
        signer_cap: SignerCapability,
    ) acquires GovernanceResponsbility {
        system_addresses::assert_aptos_framework(aptos_framework);

        if (!exists<GovernanceResponsbility>(@aptos_framework)) {
            move_to(aptos_framework, GovernanceResponsbility{ signer_caps: simple_map::create<address, SignerCapability>() });
        };

        let signer_caps = &mut borrow_global_mut<GovernanceResponsbility>(@aptos_framework).signer_caps;
        simple_map::add(signer_caps, signer_address, signer_cap);
    }

    /// Initializes the state for Aptos Governance. Can only be called during Genesis with a signer
    /// for the aptos_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);

        voting::register<GovernanceProposal>(aptos_framework);
        move_to(aptos_framework, GovernanceConfig {
            voting_duration_secs,
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
        move_to(aptos_framework, ApprovedExecutionHashes {
            hashes: simple_map::create<u64, vector<u8>>(),
        })
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// AptosGovernance.
    public fun update_governance_config(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) acquires GovernanceConfig, GovernanceEvents {
        system_addresses::assert_aptos_framework(aptos_framework);

        let governance_config = borrow_global_mut<GovernanceConfig>(@aptos_framework);
        governance_config.voting_duration_secs = voting_duration_secs;
        governance_config.min_voting_threshold = min_voting_threshold;
        governance_config.required_proposer_stake = required_proposer_stake;

        let events = borrow_global_mut<GovernanceEvents>(@aptos_framework);
        event::emit_event<UpdateConfigEvent>(
            &mut events.update_config_events,
            UpdateConfigEvent {
                min_voting_threshold,
                required_proposer_stake,
                voting_duration_secs
            },
        );
    }

    public fun get_voting_duration_secs(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).voting_duration_secs
    }

    public fun get_min_voting_threshold(): u128 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).min_voting_threshold
    }

    public fun get_required_proposer_stake(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).required_proposer_stake
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
    ) acquires GovernanceConfig, GovernanceEvents {
        let proposer_address = signer::address_of(proposer);
        assert!(stake::get_delegated_voter(stake_pool) == proposer_address, error::invalid_argument(ENOT_DELEGATED_VOTER));

        // The proposer's stake needs to be at least the required bond amount.
        let governance_config = borrow_global<GovernanceConfig>(@aptos_framework);
        let stake_balance = stake::get_current_epoch_voting_power(stake_pool);
        assert!(
            stake_balance >= governance_config.required_proposer_stake,
            error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE),
        );

        // The proposer's stake needs to be locked up at least as long as the proposal's voting period.
        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + governance_config.voting_duration_secs;
        assert!(
            stake::get_lockup_secs(stake_pool) >= proposal_expiration,
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );

        // Create and validate proposal metadata.
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

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
            governance_proposal::create_proposal(),
            execution_hash,
            governance_config.min_voting_threshold,
            proposal_expiration,
            early_resolution_vote_threshold,
            proposal_metadata,
        );

        let events = borrow_global_mut<GovernanceEvents>(@aptos_framework);
        event::emit_event<CreateProposalEvent>(
            &mut events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                proposer: proposer_address,
                stake_pool,
                execution_hash,
                proposal_metadata,
            },
        );
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

        // Ensure the voter doesn't double vote with the same stake pool.
        let voting_records = borrow_global_mut<VotingRecords>(@aptos_framework);
        let record_key = RecordKey {
            stake_pool,
            proposal_id,
        };
        assert!(
            !table::contains(&voting_records.votes, record_key),
            error::invalid_argument(EALREADY_VOTED));
        table::add(&mut voting_records.votes, record_key, true);

        // Voting power does not include pending_active or pending_inactive balances.
        // In general, the stake pool should not have pending_inactive balance if it still has lockup (required to vote)
        // And if pending_active will be added to active in the next epoch.
        let voting_power = stake::get_current_epoch_voting_power(stake_pool);
        // Short-circuit if the voter has no voting power.
        assert!(voting_power > 0, error::invalid_argument(ENO_VOTING_POWER));

        // The voter's stake needs to be locked up at least as long as the proposal's expiration.
        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(@aptos_framework, proposal_id);
        assert!(
            stake::get_lockup_secs(stake_pool) >= proposal_expiration,
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );

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

    /// Add the execution script hash of a successful governance proposal to the approved list.
    /// This is needed to bypass the mempool transaction size limit for approved governance proposal transactions that
    /// are too large (e.g. module upgrades).
    public fun add_approved_script_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@aptos_framework);
        // Prevent adding the same script hash to the list multiple times.
        assert!(
            !simple_map::contains_key(&approved_hashes.hashes, &proposal_id),
            error::invalid_argument(ESCRIPT_HASH_ALREADY_ADDED),
        );

        // Ensure the proposal can be resolved.
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@aptos_framework, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

        let execution_hash = voting::get_execution_hash<GovernanceProposal>(@aptos_framework, proposal_id);
        simple_map::add(&mut approved_hashes.hashes, proposal_id, execution_hash);
    }

    /// Resolve a successful proposal. This would fail if the proposal is not successful (not enough votes or more no
    /// than yes).
    public fun resolve(proposal_id: u64, signer_address: address): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        let proposal = voting::resolve<GovernanceProposal>(@aptos_framework, proposal_id);
        remove_approved_hash(proposal_id);
        get_signer(proposal, signer_address)
    }

    /// Remove an approved proposal's execution script hash.
    public fun remove_approved_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        assert!(
            voting::is_resolved<GovernanceProposal>(@aptos_framework, proposal_id),
            error::invalid_argument(EPROPOSAL_NOT_RESOLVED_YET),
        );

        let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@aptos_framework).hashes;
        if (simple_map::contains_key(approved_hashes, &proposal_id)) {
            simple_map::remove(approved_hashes, &proposal_id);
        };
    }

    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun reconfigure(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);
        reconfiguration::reconfigure();
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    fun get_signer(_proposal: GovernanceProposal, signer_address: address): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@aptos_framework);
        let signer_cap = simple_map::borrow(&governance_responsibility.signer_caps, &signer_address);
        create_signer_with_capability(signer_cap)
    }

    fun create_proposal_metadata(metadata_location: vector<u8>, metadata_hash: vector<u8>): SimpleMap<String, vector<u8>> {
        assert!(string::length(&utf8(metadata_location)) <= 256, error::invalid_argument(EMETADATA_LOCATION_TOO_LONG));
        assert!(string::length(&utf8(metadata_hash)) <= 256, error::invalid_argument(EMETADATA_HASH_TOO_LONG));

        let metadata = simple_map::create<String, vector<u8>>();
        simple_map::add(&mut metadata, utf8(METADATA_LOCATION_KEY), metadata_location);
        simple_map::add(&mut metadata, utf8(METADATA_HASH_KEY), metadata_hash);
        metadata
    }

    #[test_only]
    use std::vector;

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        setup_voting(&aptos_framework, &proposer, &yes_voter, &no_voter);

        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            execution_hash,
            b"",
            b"",
        );
        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(signer::address_of(&aptos_framework), 0);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // Add approved script hash.
        add_approved_script_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == execution_hash, 0);

        // Resolve the proposal.
        let account = resolve(0, @aptos_framework);
        assert!(signer::address_of(&account) == @aptos_framework, 1);
        assert!(voting::is_resolved<GovernanceProposal>(@aptos_framework, 0), 2);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 3);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        setup_voting(&aptos_framework, &proposer, &yes_voter, &no_voter);

        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            execution_hash,
            b"",
            b"",
        );
        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_approved_script_hash(0);

        // Resolve the proposal.
        voting::resolve<GovernanceProposal>(@aptos_framework, 0);
        assert!(voting::is_resolved<GovernanceProposal>(@aptos_framework, 0), 0);
        remove_approved_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 1);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_cannot_double_vote(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        setup_voting(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"",
            b"",
            b"",
        );

        // Double voting should throw an error.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_cannot_double_vote_with_different_voter_addresses(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        setup_voting(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"",
            b"",
            b"",
        );

        // Double voting should throw an error for 2 different voters if they still use the same stake pool.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
        stake::set_delegated_voter(&voter_1, signer::address_of(&voter_2));
        vote(&voter_2, signer::address_of(&voter_1), 0, true);
    }

    #[test_only]
    public fun setup_voting(
        aptos_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        use std::vector;
        use aptos_framework::account;
        use aptos_framework::coin;
        use aptos_framework::aptos_coin::{Self, AptosCoin};

        timestamp::set_time_has_started_for_testing(aptos_framework);

        // Initialize the governance.
        initialize(aptos_framework, 10, 100, 1000);
        store_signer_cap(
            aptos_framework,
            @aptos_framework,
            account::create_test_signer_cap(@aptos_framework),
        );

        // Initialize the stake pools for proposer and voters.
        let active_validators = vector::empty<address>();
        vector::push_back(&mut active_validators, signer::address_of(proposer));
        vector::push_back(&mut active_validators, signer::address_of(yes_voter));
        vector::push_back(&mut active_validators, signer::address_of(no_voter));
        stake::create_validator_set(aptos_framework, active_validators);

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        // Spread stake among active and pending_inactive because both need to be accounted for when computing voting
        // power.
        stake::create_stake_pool(proposer, coin::mint(50, &mint_cap), coin::mint(50, &mint_cap), 10000);
        stake::create_stake_pool(yes_voter, coin::mint(10, &mint_cap), coin::mint(10, &mint_cap), 10000);
        stake::create_stake_pool(no_voter, coin::mint(5, &mint_cap), coin::mint(5, &mint_cap), 10000);
        coin::destroy_mint_cap<AptosCoin>(mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
    }

    #[test(aptos_framework = @aptos_framework)]
    public entry fun test_update_governance_config(
        aptos_framework: signer) acquires GovernanceConfig, GovernanceEvents {
        initialize(&aptos_framework, 1, 2, 3);
        update_governance_config(&aptos_framework, 10, 20, 30);

        let config = borrow_global<GovernanceConfig>(@aptos_framework);
        assert!(config.min_voting_threshold == 10, 0);
        assert!(config.required_proposer_stake == 20, 1);
        assert!(config.voting_duration_secs == 30, 3);
    }

    #[test(account = @0x123)]
    #[expected_failure(abort_code = 0x50003)]
    public entry fun test_update_governance_config_unauthorized_should_fail(
        account: signer) acquires GovernanceConfig, GovernanceEvents {
        initialize(&account, 1, 2, 3);
        update_governance_config(&account, 10, 20, 30);
    }
}
