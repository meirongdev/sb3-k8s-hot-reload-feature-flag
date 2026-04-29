package demo.order.controller;

import demo.order.flags.FeatureFlags;
import demo.order.service.OrderPipeline;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private final OrderPipeline pipeline;

    public OrderController(OrderPipeline pipeline) {
        this.pipeline = pipeline;
    }

    @GetMapping("/{id}")
    public Map<String, Object> getOrder(
            @PathVariable String id,
            @RequestHeader(value = "X-User-Id", required = false) String userId) {

        // No @RequestHeader X-FF-* params anywhere — flags are picked up
        // from the request-scoped FeatureFlags holder set by FeatureFlagFilter.
        String handler = pipeline.pickHandler(id);
        FeatureFlags ff = FeatureFlags.current();

        return Map.of(
                "service", "order-service",
                "thread", Thread.currentThread().toString(),
                "orderId", id,
                "userId", userId == null ? "anonymous" : userId,
                "handler", handler,
                "tier", ff.orderTier(),
                "newPricingHint", ff.newPricing(),
                "fulfillmentMode", ff.fulfillmentMode()
        );
    }
}
