using Umbraco.Cms.Core.Routing;

namespace SampleSite.Web.Routing;

// Synthetic fixture: resolves /go/<code> to a page.
public class ShortUrlContentFinder : IContentFinder
{
    public Task<bool> TryFindContent(IPublishedRequestBuilder request)
    {
        return Task.FromResult(false);
    }
}
