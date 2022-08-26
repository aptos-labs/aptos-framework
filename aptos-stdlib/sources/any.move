module aptos_std::any {
    use aptos_std::type_info;
    use std::bcs;
    use std::error;
    use std::string::String;

    friend aptos_std::copyable_any;

    /// The type provided for `unpack` is not the same as was given for `pack`.
    const ETYPE_MISMATCH: u64 = 0;

    /// A type which can represent a value of any type. This allows for representation of 'unknown' future
    /// values. For example, to define a resource such that it can be later be extended without breaking
    /// changes one can do
    ///
    /// ```move
    ///   struct Resource {
    ///      field: Type,
    ///      ...
    ///      extension: Option<Any>
    ///   }
    /// ```
    struct Any has drop, store {
        type_name: String,
        data: vector<u8>
    }

    /// Pack a value into the `Any` representation. Because Any can be stored and dropped, this is
    /// also required from `T`.
    public fun pack<T: drop + store>(x: T): Any {
        Any {
            type_name: type_info::type_name<T>(),
            data: bcs::to_bytes(&x)
        }
    }

    /// Unpack a value from the `Any` representation. This aborts if the value has not the expected type `T`.
    public fun unpack<T>(x: Any): T {
        assert!(type_info::type_name<T>() == x.type_name, error::invalid_argument(ETYPE_MISMATCH));
        from_bytes<T>(x.data)
    }

    /// Returns the type name of this Any
    public fun type_name(x: &Any): &String {
        &x.type_name
    }

    /// Native function to deserialize a type T.
    ///
    /// Note that this function does not put any constraint on `T`. If code uses this function to
    /// deserialized a linear value, its their responsibility that the data they deserialize is
    /// owned.
    public(friend) native fun from_bytes<T>(bytes: vector<u8>): T;

    #[test_only]
    struct S has store, drop { x: u64 }

    #[test]
    fun test_any() {
        assert!(unpack<u64>(pack(22)) == 22, 1);
        assert!(unpack<S>(pack(S{x:22})) == S{x: 22}, 2);
    }
}
