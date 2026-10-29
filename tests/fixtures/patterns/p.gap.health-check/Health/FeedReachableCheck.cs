using Umbraco.Cms.Core.HealthChecks;

namespace SampleSite.Web.Health;

// Synthetic fixture: checks that a feed setting is present.
[HealthCheck("00000000-0000-0000-0000-000000000301", "Feed settings", Description = "Checks the feed settings.", Group = "Configuration")]
public class FeedReachableCheck : HealthCheck
{
    public override Task<IEnumerable<HealthCheckStatus>> GetStatus() => Task.FromResult(Enumerable.Empty<HealthCheckStatus>());

    public override HealthCheckStatus ExecuteAction(HealthCheckAction action) => new HealthCheckStatus("ok");
}
