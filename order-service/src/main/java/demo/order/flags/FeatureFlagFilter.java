package demo.order.flags;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Reads X-FF-* headers and binds the snapshot inside a {@link ScopedValue}
 * scope for the duration of the filter chain. MDC is also populated so log
 * lines emitted during the request automatically carry the flag context.
 *
 * MDC still uses ThreadLocal under the hood (slf4j contract), but it's
 * scoped per request via try/finally — same lifecycle as the ScopedValue.
 * On platform threads or virtual threads, the per-request shape stays the
 * same; ScopedValue carries the strongly-typed value, MDC carries the
 * loggable text.
 */
@Component
public class FeatureFlagFilter extends OncePerRequestFilter {

    static final String H_TIER = "X-FF-Order-Tier";
    static final String H_NEW_PRICING = "X-FF-New-Pricing";
    static final String H_FULFILLMENT_MODE = "X-FF-Fulfillment-Mode";

    static final String MDC_TIER = "ff.tier";
    static final String MDC_NEW_PRICING = "ff.newPricing";

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        FeatureFlags ff = parse(req);
        MDC.put(MDC_TIER, ff.orderTier());
        MDC.put(MDC_NEW_PRICING, Boolean.toString(ff.newPricing()));
        try {
            // Bind the scoped value for the entire downstream call. The
            // binding is removed automatically when call() returns —
            // no finally cleanup needed for the holder.
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
        String fulfillmentMode = req.getHeader(H_FULFILLMENT_MODE);
        return new FeatureFlags(
                tier != null ? tier : FeatureFlags.DEFAULTS.orderTier(),
                "true".equalsIgnoreCase(np),
                fulfillmentMode != null ? fulfillmentMode : FeatureFlags.DEFAULTS.fulfillmentMode());
    }
}
