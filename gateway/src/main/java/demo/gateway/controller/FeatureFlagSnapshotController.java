package demo.gateway.controller;

import demo.gateway.flags.FeatureFlagSnapshot;
import demo.gateway.flags.FeatureFlagSnapshotResolver;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class FeatureFlagSnapshotController {

    private final FeatureFlagSnapshotResolver resolver;

    public FeatureFlagSnapshotController(FeatureFlagSnapshotResolver resolver) {
        this.resolver = resolver;
    }

    @GetMapping("/experience/shared-flags")
    public FeatureFlagSnapshot sharedFlags(
            @RequestHeader(value = "X-User-Id", required = false) String userId,
            @RequestHeader(value = "X-Tenant-Id", required = false) String tenantId) {
        return resolver.resolve(userId, tenantId);
    }
}
