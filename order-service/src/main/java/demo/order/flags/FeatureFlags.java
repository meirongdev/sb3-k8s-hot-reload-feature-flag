package demo.order.flags;

/**
 * Per-request feature-flag snapshot. Bound at the request boundary by
 * {@link FeatureFlagFilter} via {@link ScopedValue#where} and read anywhere
 * downstream via {@link #current()}.
 *
 * Why ScopedValue instead of ThreadLocal:
 *  - Designed for virtual threads. Each VT does NOT carry its own ThreadLocalMap
 *    entry — saves memory at high VT counts.
 *  - Lifetime is bounded by the where(...).call() scope; cleanup is automatic.
 *    No risk of leaking a stale value into a thread that gets reused.
 *  - Immutable inside the scope — deeper code can read but cannot mutate,
 *    eliminating "where did this value get changed?" bugs.
 *
 * Finalised in Java 25 (JEP 506). No --enable-preview needed.
 */
public record FeatureFlags(String orderTier, boolean newPricing, String fulfillmentMode) {

    public static final FeatureFlags DEFAULTS = new FeatureFlags("standard", false, "standard");

    public static final ScopedValue<FeatureFlags> CURRENT = ScopedValue.newInstance();

    /** Returns the bound snapshot, or DEFAULTS if no scope is active. */
    public static FeatureFlags current() {
        return CURRENT.orElse(DEFAULTS);
    }
}
