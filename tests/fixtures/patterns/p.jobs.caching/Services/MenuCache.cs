using Umbraco.Cms.Core.Cache;
using Umbraco.Extensions;

namespace SampleSite.Web.Services;

// Synthetic fixture: caches the main menu.
public class MenuCache
{
    private readonly AppCaches _appCaches;

    public MenuCache(AppCaches appCaches)
    {
        _appCaches = appCaches;
    }

    public string Get() => _appCaches.RuntimeCache.GetCacheItem("sample-menu", () => "<nav></nav>") ?? string.Empty;
}
