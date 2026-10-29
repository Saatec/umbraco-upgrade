using Microsoft.Extensions.Configuration;

namespace SampleSite.Web.Configuration;

// Synthetic fixture: reads settings outside dependency injection.
public static class SiteSettings
{
    private static readonly IConfigurationRoot Root = new ConfigurationBuilder()
        .AddJsonFile("appsettings.json", optional: false)
        .Build();

    public static string? SupportEmail => Root["SampleSite:SupportEmail"];
}
