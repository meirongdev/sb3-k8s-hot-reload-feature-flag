package demo.gateway.config;

import demo.gateway.filter.FeatureFlagFilter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.function.RouterFunction;
import org.springframework.web.servlet.function.ServerResponse;

import static org.springframework.cloud.gateway.server.mvc.filter.BeforeFilterFunctions.uri;
import static org.springframework.cloud.gateway.server.mvc.handler.GatewayRouterFunctions.route;
import static org.springframework.cloud.gateway.server.mvc.handler.HandlerFunctions.http;
import static org.springframework.cloud.gateway.server.mvc.predicate.GatewayRequestPredicates.path;

@Configuration
public class RoutesConfig {

    @Bean
    public RouterFunction<ServerResponse> orderRoute(FeatureFlagFilter ffFilter) {
        return route("orders")
                .route(path("/orders/**"), http())
                .before(uri("http://order-service:8081"))
                .before(ffFilter.apply())
                .build();
    }

    @Bean
    public RouterFunction<ServerResponse> pricingRoute(FeatureFlagFilter ffFilter) {
        return route("pricing")
                .route(path("/pricing/**"), http())
                .before(uri("http://pricing-service:8082"))
                .before(ffFilter.apply())
                .build();
    }
}
