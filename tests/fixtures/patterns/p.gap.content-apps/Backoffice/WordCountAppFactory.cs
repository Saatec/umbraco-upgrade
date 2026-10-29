using Umbraco.Cms.Core.Models.ContentEditing;
using Umbraco.Cms.Core.Models.Membership;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: shows a word count next to content.
public class WordCountAppFactory : IContentAppFactory
{
    public ContentApp? GetContentAppFor(object source, IEnumerable<IReadOnlyUserGroup> userGroups) => null;
}
