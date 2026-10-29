using Newtonsoft.Json;

namespace SampleSite.Web.Services;

// Synthetic fixture: relies on a library that only arrives transitively.
public class FeedReader
{
    public T? Read<T>(string json) => JsonConvert.DeserializeObject<T>(json);
}
