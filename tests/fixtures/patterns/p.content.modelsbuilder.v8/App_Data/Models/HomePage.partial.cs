using Umbraco.Core.Models.PublishedContent;

namespace Umbraco.Web.PublishedModels
{
    // Synthetic fixture: extends a generated model.
    public partial class HomePage : PublishedContentModel
    {
        public string DisplayTitle => Name.ToUpperInvariant();
    }
}
