namespace SampleSite.Web.Services;

// Synthetic fixture: asks the CDN to drop cached copies of a URL.
public class CdnPurgeService
{
    public Task PurgeAsync(string url) => Task.CompletedTask;
}
