/// A variable-sized container that can hold any type. Indexing is 0-based, and
/// vectors are growable. This module has many native functions.
/// Verification of modules that use this one uses model functions that are implemented
/// directly in Boogie. The specification language has built-in functions operations such
/// as `singleton_vector`. There are some helper functions defined here for specifications in other
/// modules as well.
///
/// >Note: We did not verify most of the
/// Move functions here because many have loops, requiring loop invariants to prove, and
/// the return on investment didn't seem worth it for these simple functions.
module std::vector {

    /// The index into the vector is out of bounds
    const EINDEX_OUT_OF_BOUNDS: u64 = 0x20000;

    #[bytecode_instruction]
    /// Create an empty vector.
    native public fun empty<Element>(): vector<Element>;

    #[bytecode_instruction]
    /// Return the length of the vector.
    native public fun length<Element>(v: &vector<Element>): u64;

    #[bytecode_instruction]
    /// Acquire an immutable reference to the `i`th element of the vector `v`.
    /// Aborts if `i` is out of bounds.
    native public fun borrow<Element>(v: &vector<Element>, i: u64): &Element;

    #[bytecode_instruction]
    /// Add element `e` to the end of the vector `v`.
    native public fun push_back<Element>(v: &mut vector<Element>, e: Element);

    #[bytecode_instruction]
    /// Return a mutable reference to the `i`th element in the vector `v`.
    /// Aborts if `i` is out of bounds.
    native public fun borrow_mut<Element>(v: &mut vector<Element>, i: u64): &mut Element;

    #[bytecode_instruction]
    /// Pop an element from the end of vector `v`.
    /// Aborts if `v` is empty.
    native public fun pop_back<Element>(v: &mut vector<Element>): Element;

    #[bytecode_instruction]
    /// Destroy the vector `v`.
    /// Aborts if `v` is not empty.
    native public fun destroy_empty<Element>(v: vector<Element>);

    #[bytecode_instruction]
    /// Swaps the elements at the `i`th and `j`th indices in the vector `v`.
    /// Aborts if `i` or `j` is out of bounds.
    native public fun swap<Element>(v: &mut vector<Element>, i: u64, j: u64);

    /// Return an vector of size one containing element `e`.
    public fun singleton<Element>(e: Element): vector<Element> {
        let v = empty();
        push_back(&mut v, e);
        v
    }
    spec singleton {
        aborts_if false;
        ensures result == vec(e);
    }

    /// Reverses the order of the elements in the vector `v` in place.
    public fun reverse<Element>(v: &mut vector<Element>) {
        let len = length(v);
        if (len == 0) return ();

        let front_index = 0;
        let back_index = len -1;
        while (front_index < back_index) {
            swap(v, front_index, back_index);
            front_index = front_index + 1;
            back_index = back_index - 1;
        }
    }
    spec reverse {
        pragma intrinsic = true;
    }


    /// Pushes all of the elements of the `other` vector into the `lhs` vector.
    public fun append<Element>(lhs: &mut vector<Element>, other: vector<Element>) {
        reverse(&mut other);
        while (!is_empty(&other)) push_back(lhs, pop_back(&mut other));
        destroy_empty(other);
    }
    spec append {
        pragma intrinsic = true;
    }
    spec is_empty {
        pragma intrinsic = true;
    }


    /// Return `true` if the vector `v` has no elements and `false` otherwise.
    public fun is_empty<Element>(v: &vector<Element>): bool {
        length(v) == 0
    }

    /// Return true if `e` is in the vector `v`.
    public fun contains<Element>(v: &vector<Element>, e: &Element): bool {
        let i = 0;
        let len = length(v);
        while (i < len) {
            if (borrow(v, i) == e) return true;
            i = i + 1;
        };
        false
    }
    spec contains {
        pragma intrinsic = true;
    }

    /// Return `(true, i)` if `e` is in the vector `v` at index `i`.
    /// Otherwise, returns `(false, 0)`.
    public fun index_of<Element>(v: &vector<Element>, e: &Element): (bool, u64) {
        let i = 0;
        let len = length(v);
        while (i < len) {
            if (borrow(v, i) == e) return (true, i);
            i = i + 1;
        };
        (false, 0)
    }
    spec index_of {
        pragma intrinsic = true;
    }

    /// Remove the `i`th element of the vector `v`, shifting all subsequent elements.
    /// This is O(n) and preserves ordering of elements in the vector.
    /// Aborts if `i` is out of bounds.
    public fun remove<Element>(v: &mut vector<Element>, i: u64): Element {
        let len = length(v);
        // i out of bounds; abort
        if (i >= len) abort EINDEX_OUT_OF_BOUNDS;

        len = len - 1;
        while (i < len) swap(v, i, { i = i + 1; i });
        pop_back(v)
    }
    spec remove {
        pragma intrinsic = true;
    }

    /// Swap the `i`th element of the vector `v` with the last element and then pop the vector.
    /// This is O(1), but does not preserve ordering of elements in the vector.
    /// Aborts if `i` is out of bounds.
    public fun swap_remove<Element>(v: &mut vector<Element>, i: u64): Element {
        assert!(!is_empty(v), EINDEX_OUT_OF_BOUNDS);
        let last_idx = length(v) - 1;
        swap(v, i, last_idx);
        pop_back(v)
    }
    spec swap_remove {
        pragma intrinsic = true;
    }

    /// Apply the function to each element in the vector, consuming it.
    public inline fun for_each<Element>(v: vector<Element>, f: |Element|) {
        reverse(&mut v); // We need to reverse the vector to consume it efficiently
        while (!is_empty(&v)) {
            let e = pop_back(&mut v);
            f(e);
        };
    }

    /// Apply the function to a reference of each element in the vector.
    public inline fun for_each_ref<Element>(v: &vector<Element>, f: |&Element|) {
        let i = 0;
        while (i < length(v)) {
            f(borrow(v, i));
            i = i + 1
        }
    }

    /// Apply the function to a mutable reference to each element in the vector.
    public inline fun for_each_mut<Element>(v: &mut vector<Element>, f: |&mut Element|) {
        let i = 0;
        while (i < length(v)) {
            f(borrow_mut(v, i));
            i = i + 1
        }
    }

    /// Fold the function over the elements. For example, `fold(vector[1,2,3], 0, f)` will execute
    /// `f(f(f(0, 1), 2), 3)`
    public inline fun fold<Accumulator, Element>(
        v: vector<Element>,
        init: Accumulator,
        f: |Accumulator,Element|Accumulator
    ): Accumulator {
        let accu = init;
        for_each(v, |elem| accu = f(accu, elem));
        accu
    }

    /// Map the function over the references of the elements of the vector, producing a new vector without modifying the
    /// original map.
    public inline fun map_ref<Element, NewElement>(
        v: &vector<Element>,
        f: |&Element|NewElement
    ): vector<NewElement> {
        let result = vector<NewElement>[];
        for_each_ref(v, |elem| push_back(&mut result, f(elem)));
        result
    }

    /// Map the function over the elements of the vector, producing a new vector.
    public inline fun map<Element, NewElement>(
        v: vector<Element>,
        f: |Element|NewElement
    ): vector<NewElement> {
        let result = vector<NewElement>[];
        for_each(v, |elem| push_back(&mut result, f(elem)));
        result
    }

    /// Filter the vector using the boolean function, removing all elements for which `p(e)` is not true.
    public inline fun filter<Element:drop>(
        v: vector<Element>,
        p: |&Element|bool
    ): vector<Element> {
        let result = vector<Element>[];
        for_each(v, |elem| {
            if (p(&elem)) push_back(&mut result, elem);
        });
        result
    }

    /// Return true if any element in the vector satisfies the predicate.
    public inline fun any<Element>(
        v: &vector<Element>,
        p: |&Element|bool
    ): bool {
        let result = false;
        let i = 0;
        while (i < length(v)) {
            result = p(borrow(v, i));
            if (result) {
                break
            };
            i = i + 1
        };
        result
    }

    /// Return true if all elements in the vector satisfy the predicate.
    public inline fun all<Element>(
        v: &vector<Element>,
        p: |&Element|bool
    ): bool {
        let result = true;
        let i = 0;
        while (i < length(v)) {
            result = p(borrow(v, i));
            if (!result) {
                break
            };
            i = i + 1
        };
        result
    }

    // =================================================================
    // Module Specification

    spec module {} // Switch to module documentation context

    /// # Helper Functions

    spec module {
        /// Check if `v1` is equal to the result of adding `e` at the end of `v2`
        fun eq_push_back<Element>(v1: vector<Element>, v2: vector<Element>, e: Element): bool {
            len(v1) == len(v2) + 1 &&
            v1[len(v1)-1] == e &&
            v1[0..len(v1)-1] == v2[0..len(v2)]
        }

        /// Check if `v` is equal to the result of concatenating `v1` and `v2`
        fun eq_append<Element>(v: vector<Element>, v1: vector<Element>, v2: vector<Element>): bool {
            len(v) == len(v1) + len(v2) &&
            v[0..len(v1)] == v1 &&
            v[len(v1)..len(v)] == v2
        }

        /// Check `v1` is equal to the result of removing the first element of `v2`
        fun eq_pop_front<Element>(v1: vector<Element>, v2: vector<Element>): bool {
            len(v1) + 1 == len(v2) &&
            v1 == v2[1..len(v2)]
        }

        /// Check that `v1` is equal to the result of removing the element at index `i` from `v2`.
        fun eq_remove_elem_at_index<Element>(i: u64, v1: vector<Element>, v2: vector<Element>): bool {
            len(v1) + 1 == len(v2) &&
            v1[0..i] == v2[0..i] &&
            v1[i..len(v1)] == v2[i + 1..len(v2)]
        }

        /// Check if `v` contains `e`.
        fun spec_contains<Element>(v: vector<Element>, e: Element): bool {
            exists x in v: x == e
        }
    }

}
