using Umbraco.Cms.Core.DependencyInjection;
using Umbraco.Extensions;

namespace SampleSite.Web.Security;

// Synthetic fixture: registers an external login for members (provider settings come from configuration).
public static class MemberLoginExtensions
{
    public static IUmbracoBuilder AddSampleMemberLogin(this IUmbracoBuilder builder)
    {
        builder.AddMemberExternalLogins(logins =>
        {
            logins.AddMemberLogin(memberAuthenticationBuilder => { });
        });
        return builder;
    }
}
