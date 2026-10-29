using Umbraco.Cms.Core.Security;

namespace SampleSite.Web.Security;

// Synthetic fixture: a two-factor provider.
public class SampleTwoFactorProvider : ITwoFactorProvider
{
    public string ProviderName => "SampleTotp";
    public Task<object> GetSetupDataAsync(Guid userOrMemberKey, string secret) => Task.FromResult<object>(new object());
    public bool ValidateTwoFactorPIN(string secret, string token) => false;
    public bool ValidateTwoFactorSetup(string secret, string token) => false;
}
