using Umbraco.Cms.Core.Models;
using Umbraco.Cms.Core.Services;

namespace SampleSite.Web.Services;

// Synthetic fixture: writes a suggestion page under a fixed parent.
public class SuggestionWriter
{
    private readonly IContentService _contentService;

    public SuggestionWriter(IContentService contentService)
    {
        _contentService = contentService;
    }

    public void Add(Guid parentKey, string title)
    {
        IContent page = _contentService.Create(title, parentKey, "suggestion");
        _contentService.SaveAndPublish(page);
    }
}
