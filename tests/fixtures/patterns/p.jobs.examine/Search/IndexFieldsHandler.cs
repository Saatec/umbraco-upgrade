using Examine;

namespace SampleSite.Web.Search;

// Synthetic fixture: adds a combined text field before values are indexed.
public class IndexFieldsHandler
{
    public void Attach(IExamineManager examineManager)
    {
        if (examineManager.TryGetIndex("ExternalIndex", out var index) && index is BaseIndexProvider provider)
        {
            provider.TransformingIndexValues += (sender, e) => { };
        }
    }
}
