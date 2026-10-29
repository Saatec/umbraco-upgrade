using Umbraco.Cms.Core.Services;

namespace SampleSite.Web.Security;

// Synthetic fixture: checks whether a file page is protected before serving it.
public class DownloadAccess
{
    private readonly IPublicAccessService _publicAccessService;

    public DownloadAccess(IPublicAccessService publicAccessService)
    {
        _publicAccessService = publicAccessService;
    }

    public bool NeedsLogin(string path) => _publicAccessService.IsProtected(path).Success;
}
