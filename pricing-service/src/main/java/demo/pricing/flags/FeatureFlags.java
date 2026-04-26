package demo.pricing.flags;

/**
 * Per-request feature-flag snapshot. See order-service's mirror class for
 * the full ScopedValue rationale. Short version:
 *  - Replaces a ThreadLocal-based holder
 *  - Plays well with virtual threads (no per-VT map growth)
 *  - Auto-cleaned by where(...).call() scope, no finally needed
 *  - Immutable inside scope
 *
 * Finalised in Java 25 (JEP 506).
 */
public record FeatureFlags(String orderTier, boolean newPricing) {

    public static final FeatureFlags DEFAULTS = new FeatureFlags("standard", false);

    public static final ScopedValue<FeatureFlags> CURRENT = ScopedValue.newInstance();

    public static FeatureFlags current() {
        return CURRENT.orElse(DEFAULTS);
    }
}
