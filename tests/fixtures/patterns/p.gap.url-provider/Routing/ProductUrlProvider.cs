using Umbraco.Cms.Core.Models.PublishedContent;
using Umbraco.Cms.Core.Routing;

namespace SampleSite.Web.Routing;

// Synthetic fixture: builds short URLs for product pages.
public class ProductUrlProvider : IUrlProvider
{
    public UrlInfo? GetUrl(IPublishedContent content, UrlMode mode, string? culture, Uri current) => null;

    public IEnumerable<UrlInfo> GetOtherUrls(int id, Uri current) => Enumerable.Empty<UrlInfo>();
}
