import Foundation

/// Maps the Settings volume slider (0–100 %) to an `NSSound.volume` amplitude.
///
/// The slider used to feed the percentage straight through (`percent / 100`),
/// so its lowest audible stop, 5 %, still played at −26 dB. Loudness is
/// perceived logarithmically, so a linear map crams all of the "quiet" range
/// into the slider's first few pixels — there was no way to make cues truly soft.
///
/// Below `knee` the curve is quadratic, which spreads the quiet end across the
/// first quarter of the slider (1 % ≈ −68 dB, 5 % ≈ −40 dB). From `knee` up it
/// stays linear, so every setting a user already picked at or above 25 % —
/// including the 50 % default — sounds exactly as it did before.
public enum SoundVolumeCurve {
    /// Slider position where the quadratic taper hands over to the old linear map.
    public static let knee = 25

    public static func amplitude(forPercent percent: Int) -> Float {
        guard percent > 0 else { return 0 }
        guard percent < 100 else { return 1 }
        guard percent < knee else { return Float(percent) / 100 }
        let fraction = Float(percent) / Float(knee)
        return Float(knee) / 100 * fraction * fraction
    }
}
