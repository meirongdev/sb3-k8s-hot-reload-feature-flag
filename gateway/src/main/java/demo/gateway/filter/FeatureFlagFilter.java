package demo.gateway.filter;

import dev.openfeature.sdk.Client;
import dev.openfeature.sdk.MutableContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.function.ServerRequest;

import java.util.function.Function;

/**
 * Evaluates feature flags and re-builds the ServerRequest with X-FF-* headers
 * so downstream microservices can react without their own OpenFeature SDK.
 */
@Component
public class FeatureFlagFilter {

    private static final Logger log = LoggerFactory.getLogger(FeatureFlagFilter.class);
    static final String HEADER_USER_ID = "X-User-Id";
    static final String HEADER_TENANT_ID = "X-Tenant-Id";

    private final Client client;

    public FeatureFlagFilter(Client client) {
        this.client = client;
    }

    public Function<ServerRequest, ServerRequest> apply() {
        return request -> {
            MutableContext ctx = buildContext(request);

            boolean newPricing = client.getBooleanValue("new-pricing-algo", false, ctx);
            String orderTier = client.getStringValue("order-tier", "standard", ctx);

            log.debug("Resolved flags userId={} newPricing={} orderTier={}",
                    ctx.getTargetingKey(), newPricing, orderTier);

            return ServerRequest.from(request)
                    .header("X-FF-New-Pricing", Boolean.toString(newPricing))
                    .header("X-FF-Order-Tier", orderTier)
                    .build();
        };
    }

    private static MutableContext buildContext(ServerRequest request) {
        MutableContext ctx = new MutableContext();
        request.headers().header(HEADER_USER_ID).stream().findFirst().ifPresent(ctx::setTargetingKey);
        request.headers().header(HEADER_TENANT_ID).stream().findFirst().ifPresent(t -> ctx.add("tenant", t));
        return ctx;
    }
}
