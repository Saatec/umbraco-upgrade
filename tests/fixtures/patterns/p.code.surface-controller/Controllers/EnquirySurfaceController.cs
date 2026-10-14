using System.Web.Mvc;
using Umbraco.Web.Mvc;

namespace SampleSite.Web.Controllers
{
    // Synthetic fixture: handles the enquiry form post.
    public class EnquirySurfaceController : SurfaceController
    {
        [HttpPost]
        [ValidateAntiForgeryToken]
        public ActionResult Submit(EnquiryFormModel model)
        {
            if (!ModelState.IsValid)
            {
                return CurrentUmbracoPage();
            }

            TempData["EnquirySent"] = true;
            return RedirectToCurrentUmbracoPage();
        }
    }

    public class EnquiryFormModel
    {
        public string Name { get; set; }
        public string Message { get; set; }
    }
}
