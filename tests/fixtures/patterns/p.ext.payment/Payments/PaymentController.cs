using Microsoft.AspNetCore.Mvc;

namespace SampleSite.Web.Payments;

// Synthetic fixture: receives the gateway notification after a payment.
[Route("payments")]
public class PaymentController : Controller
{
    [HttpPost("callback")]
    public IActionResult PaymentCallback(string reference, string status) => Ok();
}
