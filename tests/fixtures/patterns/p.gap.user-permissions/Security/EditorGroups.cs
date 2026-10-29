using Umbraco.Cms.Core.Services;

namespace SampleSite.Web.Security;

// Synthetic fixture: grants a permission to an editor group.
public class EditorGroups
{
    private readonly IUserService _userService;

    public EditorGroups(IUserService userService)
    {
        _userService = userService;
    }

    public void AllowPublish(int groupId, int nodeId) => _userService.AssignUserGroupPermission(groupId, 'U', nodeId);
}
