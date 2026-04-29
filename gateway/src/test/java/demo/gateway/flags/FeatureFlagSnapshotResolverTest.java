package demo.gateway.flags;

import dev.openfeature.sdk.Client;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Proxy;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class FeatureFlagSnapshotResolverTest {

    @Test
    void resolvesAllScenarioFlagsForVipPremiumContext() {
        Client client = fakeClient(Map.of(
                "order-tier", "premium",
                "new-pricing-algo", true,
                "ops-fulfillment-mode", "express",
                "ui-homepage-banner", "spring-sale",
                "ui-member-perks", true
        ));

        FeatureFlagSnapshotResolver resolver = new FeatureFlagSnapshotResolver(client);

        FeatureFlagSnapshot snapshot = resolver.resolve("u-vip-001", "premium");

        assertThat(snapshot.orderTier()).isEqualTo("premium");
        assertThat(snapshot.newPricing()).isTrue();
        assertThat(snapshot.fulfillmentMode()).isEqualTo("express");
        assertThat(snapshot.homepageBanner()).isEqualTo("spring-sale");
        assertThat(snapshot.memberPerks()).isTrue();
    }

    @Test
    void fallsBackToDefaultsWhenProviderReturnsDefaults() {
        Client client = fakeClient(Map.of());

        FeatureFlagSnapshotResolver resolver = new FeatureFlagSnapshotResolver(client);

        FeatureFlagSnapshot snapshot = resolver.resolve(null, null);

        assertThat(snapshot.orderTier()).isEqualTo("standard");
        assertThat(snapshot.newPricing()).isFalse();
        assertThat(snapshot.fulfillmentMode()).isEqualTo("standard");
        assertThat(snapshot.homepageBanner()).isEqualTo("control");
        assertThat(snapshot.memberPerks()).isFalse();
    }

    private static Client fakeClient(Map<String, Object> values) {
        return (Client) Proxy.newProxyInstance(
                Client.class.getClassLoader(),
                new Class[]{Client.class},
                (proxy, method, args) -> switch (method.getName()) {
                    case "getStringValue", "getBooleanValue" -> values.getOrDefault(args[0], args[1]);
                    case "getHooks" -> List.of();
                    case "setEvaluationContext", "addHooks" -> proxy;
                    default -> null;
                }
        );
    }
}
