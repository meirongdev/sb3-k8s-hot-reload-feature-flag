package demo.order.service;

import demo.order.flags.FeatureFlags;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Demonstrates the "any deep code can read flags without method-signature
 * pollution" pattern: nothing about flags appears in this class's API.
 */
@Service
public class OrderPipeline {

    private static final Logger log = LoggerFactory.getLogger(OrderPipeline.class);

    public String pickHandler(String orderId) {
        // No method parameter, no field injection — just reach for the
        // request-scoped snapshot. MDC also carries ff.tier / ff.newPricing
        // so the log line below shows them automatically.
        FeatureFlags ff = FeatureFlags.current();
        log.info("picking handler for order={}", orderId);
        return switch (ff.orderTier()) {
            case "premium" -> "premium-order-pipeline";
            case "express" -> "express-order-pipeline";
            default -> "standard-order-pipeline";
        };
    }
}
