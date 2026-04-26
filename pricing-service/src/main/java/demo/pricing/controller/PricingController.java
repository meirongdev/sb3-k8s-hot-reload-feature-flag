package demo.pricing.controller;

import demo.pricing.config.PricingConfig;
import demo.pricing.flags.FeatureFlags;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/pricing")
public class PricingController {

    private static final Logger log = LoggerFactory.getLogger(PricingController.class);

    private final PricingConfig config;

    public PricingController(PricingConfig config) {
        this.config = config;
    }

    @GetMapping("/{sku}")
    public Map<String, Object> getPrice(@PathVariable String sku) {
        // Feature flags come from the request-scoped FeatureFlags holder
        // populated by FeatureFlagFilter, NOT from method parameters.
        FeatureFlags ff = FeatureFlags.current();
        log.info("computing price for sku={}", sku);

        BigDecimal base = new BigDecimal("100.00");
        BigDecimal afterAlgo = ff.newPricing() ? newAlgorithm(base, ff.orderTier()) : legacyAlgorithm(base);
        BigDecimal afterDiscount = applyDiscount(afterAlgo);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", "pricing-service");
        body.put("thread", Thread.currentThread().toString());
        body.put("sku", sku);
        body.put("algorithm", ff.newPricing() ? "v2-segmented" : "v1-flat");
        body.put("tier", ff.orderTier());
        body.put("price", afterDiscount.setScale(2, RoundingMode.HALF_UP));
        body.put("currency", config.getCurrency());
        body.put("discountPercent", config.getDiscountPercent());
        return body;
    }

    private BigDecimal legacyAlgorithm(BigDecimal base) {
        return base.multiply(new BigDecimal("0.95"));
    }

    private BigDecimal newAlgorithm(BigDecimal base, String tier) {
        BigDecimal multiplier = switch (tier) {
            case "premium" -> new BigDecimal("0.85");
            case "express" -> new BigDecimal("0.90");
            default -> new BigDecimal("0.95");
        };
        return base.multiply(multiplier);
    }

    private BigDecimal applyDiscount(BigDecimal price) {
        BigDecimal pct = BigDecimal.valueOf(config.getDiscountPercent());
        BigDecimal factor = BigDecimal.ONE.subtract(pct.divide(new BigDecimal("100")));
        return price.multiply(factor);
    }
}
