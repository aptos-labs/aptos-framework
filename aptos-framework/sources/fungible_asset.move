/// This defines the fungible asset module that can issue fungible asset of any `Metadata` object. The
/// metadata object can be any object that equipped with `Metadata` resource.
module aptos_framework::fungible_asset {
    use aptos_framework::event;
    use aptos_framework::object::{Self, Object, ConstructorRef};

    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;

    /// Amount cannot be zero.
    const EAMOUNT_CANNOT_BE_ZERO: u64 = 1;
    /// The transfer ref and the fungible asset do not match.
    const ETRANSFER_REF_AND_FUNGIBLE_ASSET_MISMATCH: u64 = 2;
    /// Account cannot transfer or receive fungible assets.
    const EUNGATED_TRANSFER_IS_NOT_ALLOWED: u64 = 3;
    /// Insufficient balance to withdraw or transfer.
    const EINSUFFICIENT_BALANCE: u64 = 4;
    /// The fungible asset's supply has exceeded maximum.
    const EMAX_SUPPLY_EXCEEDED: u64 = 5;
    /// More tokens than remaining supply are being burnt.
    const ESUPPLY_UNDERFLOW: u64 = 6;
    /// The mint ref and the the store do not match.
    const EMINT_REF_AND_STORE_MISMATCH: u64 = 7;
    /// Account is not the store's owner.
    const ENOT_STORE_OWNER: u64 = 8;
    /// Transfer ref and store do not match.
    const ETRANSFER_REF_AND_STORE_MISMATCH: u64 = 9;
    /// Burn ref and store do not match.
    const EBURN_REF_AND_STORE_MISMATCH: u64 = 10;
    /// Fungible asset and store do not match.
    const EFUNGIBLE_ASSET_AND_STORE_MISMATCH: u64 = 11;
    /// Cannot destroy non-empty fungible assets.
    const EAMOUNT_IS_NOT_ZERO: u64 = 12;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Define the metadata required of an metadata to be fungible.
    struct Metadata has key {
        /// The current supply of the fungible asset.
        supply: u64,
        /// The maximum supply limit where `option::none()` means no limit.
        maximum: Option<u64>,
        /// Name of the fungible metadata, i.e., "USDT".
        name: String,
        /// Symbol of the fungible metadata, usually a shorter version of the name.
        /// For example, Singapore Dollar is SGD.
        symbol: String,
        /// Number of decimals used for display purposes.
        /// For example, if `decimals` equals `2`, a balance of `505` coins should
        /// be displayed to a user as `5.05` (`505 / 10 ** 2`).
        decimals: u8,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// The store object that holds fungible assets of a specific type associated with an account.
    struct FungibleAssetStore has key {
        /// The address of the base metadata object.
        metadata: Object<Metadata>,
        /// The balance of the fungible metadata.
        balance: u64,
        /// Fungible Assets transferring is a common operation, this allows for freezing/unfreezing accounts.
        allow_ungated_transfer: bool,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FungibleAssetEvents has key {
        deposit_events: event::EventHandle<DepositEvent>,
        withdraw_events: event::EventHandle<WithdrawEvent>,
        set_ungated_transfer_events: event::EventHandle<SetUngatedTransferEvent>,
    }

    /// FungibleAsset can be passed into function for type safety and to guarantee a specific amount.
    /// FungibleAsset cannot be stored directly and will have to be deposited back into a store.
    struct FungibleAsset {
        metadata: Object<Metadata>,
        amount: u64,
    }

    /// MintRef can be used to mint the fungible asset into an account's store.
    struct MintRef has drop, store {
        metadata: Object<Metadata>
    }

    /// TransferRef can be used to allow or disallow the owner of fungible assets from transferring the asset
    /// and allow the holder of TransferRef to transfer fungible assets from any account.
    struct TransferRef has drop, store {
        metadata: Object<Metadata>
    }

    /// BurnRef can be used to burn fungible assets from a given holder account.
    struct BurnRef has drop, store {
        metadata: Object<Metadata>
    }

    /// Emitted when fungible assets are deposited into a store.
    struct DepositEvent has drop, store {
        amount: u64,
    }

    /// Emitted when fungible assets are withdrawn from a store.
    struct WithdrawEvent has drop, store {
        amount: u64,
    }

    /// Emitted when a store's ungated (owner) transfer permission is updated.
    struct SetUngatedTransferEvent has drop, store {
        transfer_allowed: bool,
    }

    /// Make an existing object fungible by adding the Metadata resource.
    /// This returns the capabilities to mint, burn, and transfer.
    public fun add_fungibility(
        constructor_ref: &ConstructorRef,
        maximum_supply: u64,
        name: String,
        symbol: String,
        decimals: u8,
    ): Object<Metadata> {
        let metadata_object_signer = &object::generate_signer(constructor_ref);
        let converted_maximum = if (maximum_supply == 0) {
            option::none()
        } else {
            option::some(maximum_supply)
        };
        move_to(metadata_object_signer,
            Metadata {
                supply: 0,
                maximum: converted_maximum,
                name,
                symbol,
                decimals,
            }
        );
        object::object_from_constructor_ref<Metadata>(constructor_ref)
    }

    /// Creates a mint ref that can be used to mint fungible assets from the given fungible object's constructor ref.
    /// This can only be called at object creation time as constructor_ref is only available then.
    public fun generate_mint_ref(constructor_ref: &ConstructorRef): MintRef {
        let metadata = object::object_from_constructor_ref<Metadata>(constructor_ref);
        MintRef { metadata }
    }

    /// Creates a burn ref that can be used to burn fungible assets from the given fungible object's constructor ref.
    /// This can only be called at object creation time as constructor_ref is only available then.
    public fun generate_burn_ref(constructor_ref: &ConstructorRef): BurnRef {
        let metadata = object::object_from_constructor_ref<Metadata>(constructor_ref);
        BurnRef { metadata }
    }

    /// Creates a transfer ref that can be used to freeze/unfreeze/transfer fungible assets from the given fungible
    /// object's constructor ref.
    /// This can only be called at object creation time as constructor_ref is only available then.
    public fun generate_transfer_ref(constructor_ref: &ConstructorRef): TransferRef {
        let metadata = object::object_from_constructor_ref<Metadata>(constructor_ref);
        TransferRef { metadata }
    }

    #[view]
    /// Get the current supply from `metadata`.
    public fun supply<T: key>(metadata: Object<T>): u64 acquires Metadata {
        borrow_fungible_metadata(&metadata).supply
    }

    #[view]
    /// Get the maximum supply from `metadata`.
    public fun maximum<T: key>(metadata: Object<T>): Option<u64> acquires Metadata {
        borrow_fungible_metadata(&metadata).maximum
    }

    #[view]
    /// Get the name of the fungible asset from `metadata`.
    public fun name<T: key>(metadata: Object<T>): String acquires Metadata {
        borrow_fungible_metadata(&metadata).name
    }

    #[view]
    /// Get the symbol of the fungible asset from `metadata`.
    public fun symbol<T: key>(metadata: Object<T>): String acquires Metadata {
        borrow_fungible_metadata(&metadata).symbol
    }

    #[view]
    /// Get the decimals from `metadata`.
    public fun decimals<T: key>(metadata: Object<T>): u8 acquires Metadata {
        borrow_fungible_metadata(&metadata).decimals
    }

    #[view]
    /// Return whether the provided address has a store initialized.
    public fun store_exists(store: address): bool {
        exists<FungibleAssetStore>(store)
    }

    /// Return the underlying metadata object
    public fun metadata_from_asset(fa: &FungibleAsset): Object<Metadata> {
        fa.metadata
    }

    #[view]
    /// Return the underlying metadata object.
    public fun store_metadata<T: key>(store: Object<T>): Object<Metadata> acquires FungibleAssetStore {
        borrow_store_resource(&store).metadata
    }

    /// Return `amount` of a given fungible asset.
    public fun amount(fa: &FungibleAsset): u64 {
        fa.amount
    }

    #[view]
    /// Get the balance of a given store.
    public fun balance<T: key>(store: Object<T>): u64 acquires FungibleAssetStore {
        if (store_exists(object::object_address(&store))) {
            borrow_store_resource(&store).balance
        } else {
            0
        }
    }

    #[view]
    /// Return whether a store can freely send or receive fungible assets.
    /// If the store has not been created, we default to returning true as deposits can be sent to it.
    public fun ungated_transfer_allowed<T: key>(store: Object<T>): bool acquires FungibleAssetStore {
        !store_exists(object::object_address(&store)) ||
            borrow_store_resource(&store).allow_ungated_transfer
    }

    public fun asset_metadata(fa: &FungibleAsset): Object<Metadata> {
        fa.metadata
    }

    /// Get the underlying metadata object from `MintRef`.
    public fun mint_ref_metadata(ref: &MintRef): Object<Metadata> {
        ref.metadata
    }

    /// Get the underlying metadata object from `TransferRef`.
    public fun transfer_ref_metadata(ref: &TransferRef): Object<Metadata> {
        ref.metadata
    }

    /// Get the underlying metadata object from `BurnRef`.
    public fun burn_ref_metadata(ref: &BurnRef): Object<Metadata> {
        ref.metadata
    }

    /// Transfer `amount` of fungible asset from `from_store`, which should be owned by `sender`, to `receiver`.
    /// Note: it does not move the underlying object.
    public entry fun transfer<T: key>(
        sender: &signer,
        from: Object<T>,
        to: Object<T>,
        amount: u64,
    ) acquires FungibleAssetStore, FungibleAssetEvents {
        let fa = withdraw(sender, from, amount);
        deposit(to, fa);
    }

    /// Allow an object to hold a store for fungible assets.
    /// Applications can use this to create multiple stores for isolating fungible assets for different purposes.
    public fun create_store<T: key>(
        constructor_ref: &ConstructorRef,
        metadata: Object<T>,
    ): Object<FungibleAssetStore> {
        let store_obj = &object::generate_signer(constructor_ref);
        let metadata = object::convert<T, Metadata>(metadata);
        move_to(store_obj, FungibleAssetStore {
            metadata,
            balance: 0,
            allow_ungated_transfer: true,
        });
        move_to(store_obj,
            FungibleAssetEvents {
                deposit_events: object::new_event_handle<DepositEvent>(store_obj),
                withdraw_events: object::new_event_handle<WithdrawEvent>(store_obj),
                set_ungated_transfer_events: object::new_event_handle<SetUngatedTransferEvent>(store_obj),
            }
        );

        object::object_from_constructor_ref<FungibleAssetStore>(constructor_ref)
    }

    /// Withdraw `amount` of fungible asset from `store` by the owner.
    public fun withdraw<T: key>(
        owner: &signer,
        store: Object<T>,
        amount: u64,
    ): FungibleAsset acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(object::owns(store, signer::address_of(owner)), error::permission_denied(ENOT_STORE_OWNER));
        assert!(ungated_transfer_allowed(store), error::invalid_argument(EUNGATED_TRANSFER_IS_NOT_ALLOWED));
        withdraw_internal(object::object_address(&store), amount)
    }

    /// Deposit `amount` of fungible asset to `store`.
    public fun deposit<T: key>(store: Object<T>, fa: FungibleAsset) acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(ungated_transfer_allowed(store), error::invalid_argument(EUNGATED_TRANSFER_IS_NOT_ALLOWED));
        deposit_internal(store, fa);
    }

    /// Mint the specified `amount` of fungible asset.
    public fun mint(ref: &MintRef, amount: u64): FungibleAsset acquires Metadata {
        assert!(amount > 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));
        let metadata = ref.metadata;
        increase_supply(&metadata, amount);

        FungibleAsset {
            metadata,
            amount
        }
    }

    /// Mint the specified `amount` of fungible asset to a destination store.
    public fun mint_to<T: key>(
        ref: &MintRef,
        store: Object<T>,
        amount: u64,
    ) acquires Metadata, FungibleAssetStore, FungibleAssetEvents {
        deposit(store, mint(ref, amount));
    }

    /// Enable/disable a store's ability to do direct transfers of fungible asset.
    public fun set_ungated_transfer<T: key>(
        ref: &TransferRef,
        store: Object<T>,
        allow: bool,
    ) acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(
            ref.metadata == store_metadata(store),
            error::invalid_argument(ETRANSFER_REF_AND_STORE_MISMATCH),
        );
        let store_addr = object::object_address(&store);
        borrow_global_mut<FungibleAssetStore>(store_addr).allow_ungated_transfer = allow;

        let events = borrow_global_mut<FungibleAssetEvents>(store_addr);
        event::emit_event(&mut events.set_ungated_transfer_events, SetUngatedTransferEvent { transfer_allowed: allow });
    }

    /// Burn the `amount` of fungible metadata from the given store.
    public fun burn<T: key>(
        ref: &BurnRef,
        store: Object<T>,
        amount: u64
    ) acquires Metadata, FungibleAssetStore, FungibleAssetEvents {
        let metadata = ref.metadata;
        assert!(metadata == store_metadata(store), error::invalid_argument(EBURN_REF_AND_STORE_MISMATCH));
        let store_addr = object::object_address(&store);
        let FungibleAsset {
            metadata,
            amount,
        } = withdraw_internal(store_addr, amount);
        decrease_supply(&metadata, amount);
    }

    /// Withdraw `amount` of fungible metadata from `store` ignoring `allow_ungated_transfer`.
    public fun withdraw_with_ref<T: key>(
        ref: &TransferRef,
        store: Object<T>,
        amount: u64
    ): FungibleAsset acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(
            ref.metadata == store_metadata(store),
            error::invalid_argument(ETRANSFER_REF_AND_STORE_MISMATCH),
        );
        withdraw_internal(object::object_address(&store), amount)
    }

    /// Deposit fungible asset into `store` ignoring `allow_ungated_transfer`.
    public fun deposit_with_ref<T: key>(
        ref: &TransferRef,
        store: Object<T>,
        fa: FungibleAsset
    ) acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(
            ref.metadata == fa.metadata,
            error::invalid_argument(ETRANSFER_REF_AND_FUNGIBLE_ASSET_MISMATCH)
        );
        deposit_internal(store, fa);
    }

    /// Transfer `ammount` of  fungible metadata with `TransferRef` even ungated transfer is disabled.
    public fun transfer_with_ref<T: key>(
        transfer_ref: &TransferRef,
        from: Object<T>,
        to: Object<T>,
        amount: u64,
    ) acquires FungibleAssetStore, FungibleAssetEvents {
        let fa = withdraw_with_ref(transfer_ref, from, amount);
        deposit_with_ref(transfer_ref, to, fa);
    }

    /// Extract a given amount from the given fungible asset and return a new one.
    public fun extract(fungible_asset: &mut FungibleAsset, amount: u64): FungibleAsset {
        assert!(fungible_asset.amount >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));
        fungible_asset.amount = fungible_asset.amount - amount;
        FungibleAsset {
            metadata: fungible_asset.metadata,
            amount,
        }
    }

    /// "Merges" the two given fungible assets. The coin passed in as `dst_fungible_asset` will have a value equal
    /// to the sum of the two (`dst_fungible_asset` and `src_fungible_asset`).
    public fun merge(dst_fungible_asset: &mut FungibleAsset, src_fungible_asset: FungibleAsset) {
        let FungibleAsset { metadata: _, amount } = src_fungible_asset;
        dst_fungible_asset.amount = dst_fungible_asset.amount + amount;
    }

    /// Destroy an empty fungible asset.
    public fun destroy_zero(fungible_asset: FungibleAsset) {
        let FungibleAsset { amount, metadata: _ } = fungible_asset;
        assert!(amount == 0, error::invalid_argument(EAMOUNT_IS_NOT_ZERO));
    }

    fun deposit_internal<T: key>(
        store: Object<T>,
        fa: FungibleAsset
    ) acquires FungibleAssetStore, FungibleAssetEvents {
        let FungibleAsset { metadata, amount } = fa;
        let store_metadata = store_metadata(store);
        assert!(metadata == store_metadata, error::invalid_argument(EFUNGIBLE_ASSET_AND_STORE_MISMATCH));
        let store_addr = object::object_address(&store);
        let store = borrow_global_mut<FungibleAssetStore>(store_addr);
        store.balance = store.balance + amount;

        let events = borrow_global_mut<FungibleAssetEvents>(store_addr);
        event::emit_event(&mut events.deposit_events, DepositEvent { amount });
    }

    /// Extract `amount` of fungible asset from `store`.
    fun withdraw_internal(
        store_addr: address,
        amount: u64,
    ): FungibleAsset acquires FungibleAssetStore, FungibleAssetEvents {
        assert!(amount != 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));
        let store = borrow_global_mut<FungibleAssetStore>(store_addr);
        assert!(store.balance >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));
        store.balance = store.balance - amount;

        let events = borrow_global_mut<FungibleAssetEvents>(store_addr);
        let metadata = store.metadata;
        event::emit_event(&mut events.withdraw_events, WithdrawEvent { amount });

        FungibleAsset { metadata, amount }
    }

    /// Increase the supply of a fungible metadata by minting.
    fun increase_supply<T: key>(metadata: &Object<T>, amount: u64) acquires Metadata {
        assert!(amount != 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));
        let fungible_metadata = borrow_fungible_metadata_mut(metadata);
        if (option::is_some(&fungible_metadata.maximum)) {
            let max = *option::borrow(&fungible_metadata.maximum);
            assert!(max - fungible_metadata.supply >= amount, error::invalid_argument(EMAX_SUPPLY_EXCEEDED))
        };
        fungible_metadata.supply = fungible_metadata.supply + amount;
    }

    /// Decrease the supply of a fungible metadata by burning.
    fun decrease_supply<T: key>(metadata: &Object<T>, amount: u64) acquires Metadata {
        assert!(amount != 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));
        let fungible_metadata = borrow_fungible_metadata_mut(metadata);
        assert!(fungible_metadata.supply >= amount, error::invalid_argument(ESUPPLY_UNDERFLOW));
        fungible_metadata.supply = fungible_metadata.supply - amount;
    }

    inline fun borrow_fungible_metadata<T: key>(
        metadata: &Object<T>
    ): &Metadata acquires Metadata {
        let addr = object::object_address(metadata);
        borrow_global<Metadata>(addr)
    }

    inline fun borrow_fungible_metadata_mut<T: key>(
        metadata: &Object<T>
    ): &mut Metadata acquires Metadata {
        let addr = object::object_address(metadata);
        borrow_global_mut<Metadata>(addr)
    }

    inline fun borrow_store_resource<T: key>(store: &Object<T>): &FungibleAssetStore acquires FungibleAssetStore {
        borrow_global<FungibleAssetStore>(object::object_address(store))
    }

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::account;

    #[test_only]
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct TestToken has key {}

    #[test_only]
    public fun create_test_token(creator: &signer): (ConstructorRef, Object<TestToken>) {
        account::create_account_for_test(signer::address_of(creator));
        let creator_ref = object::create_object_from_account(creator);
        let object_signer = object::generate_signer(&creator_ref);
        move_to(&object_signer, TestToken {});

        let token = object::object_from_constructor_ref<TestToken>(&creator_ref);
        (creator_ref, token)
    }

    #[test_only]
    public fun init_test_metadata(constructor_ref: &ConstructorRef): (MintRef, TransferRef, BurnRef) {
        add_fungibility(
            constructor_ref,
            100 /* max supply */,
            string::utf8(b"USDA"),
            string::utf8(b"$$$"),
            0
        );
        let mint_ref = generate_mint_ref(constructor_ref);
        let burn_ref = generate_burn_ref(constructor_ref);
        let transfer_ref = generate_transfer_ref(constructor_ref);
        (mint_ref, transfer_ref, burn_ref)
    }

    #[test_only]
    public fun create_fungible_asset(
        creator: &signer
    ): (MintRef, TransferRef, BurnRef, Object<TestToken>) {
        let (creator_ref, metadata) = create_test_token(creator);
        let (mint, transfer, burn) = init_test_metadata(&creator_ref);
        (mint, transfer, burn, metadata)
    }

    #[test_only]
    public fun create_test_store<T: key>(owner: &signer, metadata: Object<T>): Object<FungibleAssetStore> {
        let owner_addr = signer::address_of(owner);
        if (!account::exists_at(owner_addr)) {
            account::create_account_for_test(owner_addr);
        };
        create_store(&object::create_object_from_account(owner), metadata)
    }

    #[test(creator = @0xcafe)]
    fun test_metadata_basic_flow(creator: &signer) acquires Metadata {
        let (creator_ref, asset) = create_test_token(creator);
        init_test_metadata(&creator_ref);
        assert!(supply(asset) == 0, 1);
        assert!(maximum(asset) == option::some(100), 2);
        assert!(name(asset) == string::utf8(b"USDA"), 3);
        assert!(symbol(asset) == string::utf8(b"$$$"), 4);
        assert!(decimals(asset) == 0, 5);

        increase_supply(&asset, 50);
        assert!(supply(asset) == 50, 6);
        decrease_supply(&asset, 30);
        assert!(supply(asset) == 20, 7);
    }

    #[test(creator = @0xcafe)]
    #[expected_failure(abort_code = 0x10005, location = Self)]
    fun test_supply_overflow(creator: &signer) acquires Metadata {
        let (creator_ref, asset) = create_test_token(creator);
        init_test_metadata(&creator_ref);
        increase_supply(&asset, 101);
    }

    #[test(creator = @0xcafe)]
    #[expected_failure(abort_code = 0x10006, location = Self)]
    fun test_supply_underflow(creator: &signer) acquires Metadata {
        let (creator_ref, asset) = create_test_token(creator);
        init_test_metadata(&creator_ref);
        decrease_supply(&asset, 1);
    }

    #[test(creator = @0xcafe, aaron = @0xface)]
    fun test_e2e_basic_flow(
        creator: &signer,
        aaron: &signer,
    ) acquires Metadata, FungibleAssetStore, FungibleAssetEvents {
        let (mint_ref, transfer_ref, burn_ref, test_token) = create_fungible_asset(creator);
        let metadata = mint_ref.metadata;
        let creator_store = create_test_store(creator, metadata);
        let aaron_store = create_test_store(aaron, metadata);

        assert!(supply(test_token) == 0, 1);
        // Mint
        let fa = mint(&mint_ref, 100);
        assert!(supply(test_token) == 100, 2);
        // Deposit
        deposit(creator_store, fa);
        // Withdraw
        let fa = withdraw(creator, creator_store, 80);
        assert!(supply(test_token) == 100, 3);
        deposit(aaron_store, fa);
        // Burn
        burn(&burn_ref, aaron_store, 30);
        assert!(supply(test_token) == 70, 4);
        // Transfer
        transfer(creator, creator_store, aaron_store, 10);
        assert!(balance(creator_store) == 10, 5);
        assert!(balance(aaron_store) == 60, 6);

        set_ungated_transfer(&transfer_ref, aaron_store, false);
        assert!(!ungated_transfer_allowed(aaron_store), 7);
    }

    #[test(creator = @0xcafe)]
    #[expected_failure(abort_code = 0x10003, location = Self)]
    fun test_ungated_transfer(
        creator: &signer
    ) acquires Metadata, FungibleAssetStore, FungibleAssetEvents {
        let (mint_ref, transfer_ref, _burn_ref, _) = create_fungible_asset(creator);

        let creator_store = create_test_store(creator, mint_ref.metadata);
        let fa = mint(&mint_ref, 100);
        set_ungated_transfer(&transfer_ref, creator_store, false);
        deposit(creator_store, fa);
    }

    #[test(creator = @0xcafe, aaron = @0xface)]
    fun test_transfer_with_ref(
        creator: &signer,
        aaron: &signer,
    ) acquires Metadata, FungibleAssetStore, FungibleAssetEvents {
        let (mint_ref, transfer_ref, _burn_ref, _) = create_fungible_asset(creator);
        let metadata = mint_ref.metadata;
        let creator_store = create_test_store(creator, metadata);
        let aaron_store = create_test_store(aaron, metadata);

        let fa = mint(&mint_ref, 100);
        set_ungated_transfer(&transfer_ref, creator_store, false);
        set_ungated_transfer(&transfer_ref, aaron_store, false);
        deposit_with_ref(&transfer_ref, creator_store, fa);
        transfer_with_ref(&transfer_ref, creator_store, aaron_store, 80);
        assert!(balance(creator_store) == 20, 1);
        assert!(balance(aaron_store) == 80, 2);
        assert!(!ungated_transfer_allowed(creator_store), 3);
        assert!(!ungated_transfer_allowed(aaron_store), 4);
    }
}
