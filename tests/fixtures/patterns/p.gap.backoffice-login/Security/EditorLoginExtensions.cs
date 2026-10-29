using Umbraco.Cms.Core.DependencyInjection;
using Umbraco.Extensions;

namespace SampleSite.Web.Security;

// Synthetic fixture: registers an external login for backoffice users (provider settings come from configuration).
public static class EditorLoginExtensions
{
    public static IUmbracoBuilder AddSampleEditorLogin(this IUmbracoBuilder builder)
        => builder.AddBackOfficeExternalLogins(logins => { });
}
