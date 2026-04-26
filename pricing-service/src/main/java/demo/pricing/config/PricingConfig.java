package demo.pricing.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * Hot-reloadable pricing parameters. Values come from /etc/pricing-config/
 * (mounted ConfigMap) via configtree property source.
 *
 * Auto-rebinds on /actuator/refresh thanks to spring-cloud-context's
 * EnvironmentChangeEvent listener — controllers must read via getters,
 * never copy field values, or they will see the stale snapshot.
 */
@ConfigurationProperties("pricing")
@Component
public class PricingConfig {
    private int discountPercent = 5;
    private String currency = "USD";

    public int getDiscountPercent() { return discountPercent; }
    public void setDiscountPercent(int discountPercent) { this.discountPercent = discountPercent; }

    public String getCurrency() { return currency; }
    public void setCurrency(String currency) { this.currency = currency; }
}
