package demo.gateway.filter;

import demo.gateway.flags.FeatureFlagSnapshot;
import demo.gateway.flags.FeatureFlagSnapshotResolver;
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
    static final String HEADER_FULFILLMENT_MODE = "X-FF-Fulfillment-Mode";

    private final FeatureFlagSnapshotResolver resolver;

    public FeatureFlagFilter(FeatureFlagSnapshotResolver resolver) {
        this.resolver = resolver;
    }

    public Function<ServerRequest, ServerRequest> apply() {
        return request -> {
            FeatureFlagSnapshot snapshot = resolver.resolve(
                    request.headers().firstHeader(HEADER_USER_ID),
                    request.headers().firstHeader(HEADER_TENANT_ID)
            );

            log.debug("Resolved flags userId={} newPricing={} orderTier={}",
                    request.headers().firstHeader(HEADER_USER_ID), snapshot.newPricing(), snapshot.orderTier());

            return ServerRequest.from(request)
                    .header("X-FF-New-Pricing", Boolean.toString(snapshot.newPricing()))
                    .header("X-FF-Order-Tier", snapshot.orderTier())
                    .header(HEADER_FULFILLMENT_MODE, snapshot.fulfillmentMode())
                    .build();
        };
    }
}
