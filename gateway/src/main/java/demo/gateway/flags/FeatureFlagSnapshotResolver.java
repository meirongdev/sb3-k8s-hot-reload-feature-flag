package demo.gateway.flags;

import dev.openfeature.sdk.Client;
import dev.openfeature.sdk.MutableContext;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class FeatureFlagSnapshotResolver {

    private final Client client;

    public FeatureFlagSnapshotResolver(Client client) {
        this.client = client;
    }

    public FeatureFlagSnapshot resolve(String userId, String tenantId) {
        MutableContext ctx = buildContext(userId, tenantId);
        return new FeatureFlagSnapshot(
                client.getStringValue("order-tier", "standard", ctx),
                client.getBooleanValue("new-pricing-algo", false, ctx),
                client.getStringValue("ops-fulfillment-mode", "standard", ctx),
                client.getStringValue("ui-homepage-banner", "control", ctx),
                client.getBooleanValue("ui-member-perks", false, ctx)
        );
    }

    private static MutableContext buildContext(String userId, String tenantId) {
        MutableContext ctx = new MutableContext();
        if (StringUtils.hasText(userId)) {
            ctx.setTargetingKey(userId);
        }
        if (StringUtils.hasText(tenantId)) {
            ctx.add("tenant", tenantId);
        }
        return ctx;
    }
}
