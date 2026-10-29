using Umbraco.Cms.Core.DependencyInjection;

namespace SampleSite.Web.Media;

// Synthetic fixture: moves media to blob storage (settings come from configuration).
public static class MediaStorageExtensions
{
    public static IUmbracoBuilder AddSampleMediaStorage(this IUmbracoBuilder builder)
        => builder.AddAzureBlobMediaFileSystem();
}
