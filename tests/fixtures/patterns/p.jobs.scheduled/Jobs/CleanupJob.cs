using Umbraco.Cms.Infrastructure.BackgroundJobs;

namespace SampleSite.Web.Jobs;

// Synthetic fixture: runs every hour.
public class CleanupJob : IRecurringBackgroundJob
{
    public TimeSpan Period => TimeSpan.FromHours(1);
    public TimeSpan Delay => TimeSpan.FromMinutes(5);
    public Umbraco.Cms.Core.Sync.ServerRole[] ServerRoles => new[] { Umbraco.Cms.Core.Sync.ServerRole.Single };
    public event EventHandler PeriodChanged { add { } remove { } }
    public Task RunJobAsync() => Task.CompletedTask;
}
