package demo.pricing.flags;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
public class FeatureFlagFilter extends OncePerRequestFilter {

    static final String H_TIER = "X-FF-Order-Tier";
    static final String H_NEW_PRICING = "X-FF-New-Pricing";

    static final String MDC_TIER = "ff.tier";
    static final String MDC_NEW_PRICING = "ff.newPricing";

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        FeatureFlags ff = parse(req);
        MDC.put(MDC_TIER, ff.orderTier());
        MDC.put(MDC_NEW_PRICING, Boolean.toString(ff.newPricing()));
        try {
            ScopedValue.where(FeatureFlags.CURRENT, ff).call(() -> {
                chain.doFilter(req, res);
                return null;
            });
        } catch (ServletException | IOException | RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new ServletException("filter chain failed", t);
        } finally {
            MDC.remove(MDC_TIER);
            MDC.remove(MDC_NEW_PRICING);
        }
    }

    private static FeatureFlags parse(HttpServletRequest req) {
        String tier = req.getHeader(H_TIER);
        String np = req.getHeader(H_NEW_PRICING);
        return new FeatureFlags(
                tier != null ? tier : FeatureFlags.DEFAULTS.orderTier(),
                "true".equalsIgnoreCase(np));
    }
}
