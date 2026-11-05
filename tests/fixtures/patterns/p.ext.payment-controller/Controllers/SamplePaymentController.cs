using Microsoft.AspNetCore.Mvc;

namespace SampleSite.Controllers
{
    public class SamplePaymentController : Controller
    {
        public IActionResult Start() => View();
    }
}
