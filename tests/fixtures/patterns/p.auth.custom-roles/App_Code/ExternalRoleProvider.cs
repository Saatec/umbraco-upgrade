using System.Web.Security;

namespace SampleSite.Web
{
    // Synthetic fixture: member roles from an external system.
    public class ExternalRoleProvider : RoleProvider
    {
        public override string ApplicationName { get; set; }
        public override string[] GetRolesForUser(string username) => new[] { "Subscriber" };
        public override bool IsUserInRole(string username, string roleName) => roleName == "Subscriber";
        public override void AddUsersToRoles(string[] usernames, string[] roleNames) { }
        public override void CreateRole(string roleName) { }
        public override bool DeleteRole(string roleName, bool throwOnPopulatedRole) => false;
        public override string[] FindUsersInRole(string roleName, string usernameToMatch) => new string[0];
        public override string[] GetAllRoles() => new[] { "Subscriber" };
        public override string[] GetUsersInRole(string roleName) => new string[0];
        public override void RemoveUsersFromRoles(string[] usernames, string[] roleNames) { }
        public override bool RoleExists(string roleName) => roleName == "Subscriber";
    }
}
