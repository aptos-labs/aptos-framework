spec aptos_std::type_info {

    spec native fun spec_is_struct<T>(): bool;

    spec type_of<T>(): TypeInfo {
        // Move Prover natively supports this function.
        // This function will abort if `T` is not a struct type.
    }

    spec type_name<T>(): string::String {
        // Move Prover natively supports this function.
    }

    spec chain_id(): u8 {
        // TODO: Requires the bit operation support to specify the aborts_if condition.
        ensures result == spec_chain_id_internal();
    }

    spec chain_id_internal(): u8 {
        pragma opaque;
        aborts_if false;
        ensures result == spec_chain_id_internal();
    }

    // The chain ID is modeled as an uninterpreted function.
    spec fun spec_chain_id_internal(): u8;
}
