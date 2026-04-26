package demo.gateway.config;

import dev.openfeature.contrib.providers.flagd.FlagdOptions;
import dev.openfeature.contrib.providers.flagd.FlagdProvider;
import dev.openfeature.sdk.Client;
import dev.openfeature.sdk.OpenFeatureAPI;
import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenFeatureConfig {

    @Value("${flagd.host:flagd}")
    private String flagdHost;

    @Value("${flagd.port:8013}")
    private int flagdPort;

    @PostConstruct
    void registerProvider() {
        FlagdOptions options = FlagdOptions.builder()
                .host(flagdHost)
                .port(flagdPort)
                .build();
        // Non-blocking — provider connects asynchronously. Evaluations made
        // before READY return their defaults, which is what we want during
        // pod startup or flagd hiccups (no crash-loop).
        OpenFeatureAPI.getInstance().setProvider(new FlagdProvider(options));
    }

    @Bean
    Client featureClient() {
        return OpenFeatureAPI.getInstance().getClient("gateway");
    }
}
