using Umbraco.Cms.Core.Models.PublishedContent;

namespace SampleSite.Core.Services;

public class GreetingService
{
    public string Greet(IPublishedContent page) => $"Welcome to {page.Name}";
}
