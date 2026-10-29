using Umbraco.Cms.Core;
using Umbraco.Cms.Core.Models.PublishedContent;

namespace SampleSite.Web.Services;

// Synthetic fixture: looks up the news root by a hard-coded integer ID.
public class NewsRoot
{
    private readonly IPublishedContentQuery _query;

    public NewsRoot(IPublishedContentQuery query)
    {
        _query = query;
    }

    public IPublishedContent? Get() => _query.Content(1234);
}
