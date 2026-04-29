package demo.order.service;

import demo.order.flags.FeatureFlags;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OrderPipelineTest {

    private final OrderPipeline pipeline = new OrderPipeline();

    @Test
    void picksExpressHandlerWhenBackendOnlyFulfillmentFlagIsExpress() throws Exception {
        String handler = ScopedValue.where(
                FeatureFlags.CURRENT,
                new FeatureFlags("standard", false, "express")
        ).call(() -> pipeline.pickHandler("o-201"));

        assertThat(handler).isEqualTo("express-order-pipeline");
    }

    @Test
    void keepsPremiumHandlerWhenFulfillmentModeIsStandard() throws Exception {
        String handler = ScopedValue.where(
                FeatureFlags.CURRENT,
                new FeatureFlags("premium", false, "standard")
        ).call(() -> pipeline.pickHandler("o-202"));

        assertThat(handler).isEqualTo("premium-order-pipeline");
    }
}
