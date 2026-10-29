using System.Web.Mvc;
using Umbraco.Web.Security;

namespace SampleSite.Web
{
    // Synthetic fixture: member login through the legacy helper.
    public class MemberLoginController : Controller
    {
        private readonly MembershipHelper _members;

        public MemberLoginController(MembershipHelper members)
        {
            _members = members;
        }

        [HttpPost]
        public ActionResult Login(string username, string password)
        {
            if (_members.Login(username, password))
            {
                return Redirect("/");
            }
            return View();
        }
    }
}
