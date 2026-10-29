using System.Web.Mvc;

namespace SampleSite.Web.Controllers
{
    // Synthetic fixture: a child action that renders the site menu.
    public class NavigationController : Controller
    {
        [ChildActionOnly]
        public ActionResult Menu()
        {
            return PartialView("~/Views/Partials/Menu.cshtml");
        }
    }
}
