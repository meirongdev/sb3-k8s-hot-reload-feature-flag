package demo.gateway.flags;

public record FeatureFlagSnapshot(
        String orderTier,
        boolean newPricing,
        String fulfillmentMode,
        String homepageBanner,
        boolean memberPerks
) {
}
