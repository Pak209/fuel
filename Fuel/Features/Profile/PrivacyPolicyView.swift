import SwiftUI

/// The full in-app privacy policy for Fuel, shown from Profile → About → Privacy policy.
///
/// This is a static, offline screen: it makes no network requests, stores no state, and
/// reads no external content. Its text must stay identical to the hostable copies at
/// `docs/legal/privacy-policy.md` and `docs/legal/privacy-policy.html` — update all three
/// together whenever the policy changes.
struct PrivacyPolicyView: View {
    private struct PolicySection: Identifiable {
        let id = UUID()
        let title: String
        let paragraphs: [String]
    }

    private let effectiveDate = "August 22, 2026"

    private let introduction = "Fuel is a nutrition and hydration tracking app built to work entirely on your iPhone. This policy explains what information Fuel keeps, where it lives, and what, if anything, ever leaves your device. It is written in plain language, and there is no separate version that says something different."

    private let sections: [PolicySection] = [
        PolicySection(title: "The short version", paragraphs: [
            "Everything you log in Fuel — meals, hydration, your profile, and your goals — stays on your iPhone in a local, protected database. Apple Health data is read on-device and never leaves. The only information Fuel sends anywhere is the text you type into food search, sent to Open Food Facts so it can look up branded foods. Fuel has no user accounts, no analytics, and no advertising in this version."
        ]),
        PolicySection(title: "Nutrition, hydration, and profile data", paragraphs: [
            "Your meals, food items, portions, hydration entries, profile details, and goals are stored in a local database on your iPhone, protected by iOS Data Protection. This data is not uploaded, synced, or backed up to any Fuel server, because no Fuel server is configured in this version of the app. It stays on your device until you edit or delete it, or delete the app."
        ]),
        PolicySection(title: "Meal photos", paragraphs: [
            "When you attach a photo to a meal, Fuel saves it as a protected file on your iPhone. Photos are used only to help you remember or recognize a meal, and they are never uploaded anywhere in this version of the app. A meal's photo is deleted automatically when you delete that meal, and photos that are no longer attached to any meal are cleaned up automatically. Meal photos are not included in JSON data exports."
        ]),
        PolicySection(title: "Apple Health", paragraphs: [
            "If you choose to connect Apple Health, Fuel only reads data, such as activity, workouts, and sleep, to show you an on-device summary alongside your nutrition and hydration logs. Fuel never writes anything back to Apple Health, and your Health data is never transmitted off your device. Health data is not included in JSON data exports. It stays under Apple's own Health privacy controls, which you can review or revoke at any time in the Health app or in Settings."
        ]),
        PolicySection(title: "Food search and Open Food Facts", paragraphs: [
            "When you search for a branded food, Fuel sends only the text you typed to Open Food Facts, a free, community-maintained food database, so it can return matching products. No account information, health data, or any other identifying data is attached to that request.",
            "Food data returned by Open Food Facts is provided under the Open Database License (ODbL). Fuel credits Open Food Facts wherever that data is shown."
        ]),
        PolicySection(title: "Accounts", paragraphs: [
            "Fuel does not use accounts in this version. You do not need to sign up, sign in, or create a profile on any server to use the app."
        ]),
        PolicySection(title: "Analytics and tracking", paragraphs: [
            "Fuel does not collect analytics or tracking data, and it contains no advertising or advertising identifiers. An on-device usage-counting mechanism exists in the app's code for a possible future self-diagnosis screen, but it is switched off by default, has no network destination to send data to, and is not turned on in this version."
        ]),
        PolicySection(title: "Notifications", paragraphs: [
            "Meal, hydration, and summary reminders are scheduled and delivered locally by your iPhone. Fuel does not use push notifications or a notification server, and no notification content is sent anywhere."
        ]),
        PolicySection(title: "Your data, your control", paragraphs: [
            "From Profile, Export or delete data, you can prepare a JSON export of your profile, targets, meals, food items, and hydration logs at any time, and share or save it yourself. From the same screen, you can permanently delete all local Fuel data, including meals, photos, hydration logs, profile, goals, preferences, and caches, from your device in one step. Exporting first is recommended, since deletion cannot be undone."
        ]),
        PolicySection(title: "What never leaves your device", paragraphs: [
            "With the single exception of the text you type into food search, nothing in Fuel is transmitted off your iPhone in this version. Not your meals, not your photos, not your Health data, not your profile, and not usage data."
        ]),
        PolicySection(title: "Changes to this policy", paragraphs: [
            "If this policy changes, the update will ship together with a future app update, and the effective date above will change accordingly."
        ]),
        PolicySection(title: "Contact", paragraphs: [
            "Questions about this policy or your data can be sent to dankimoto8@gmail.com."
        ])
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fuel Privacy Policy")
                        .font(.title2.bold())
                    Text("Effective date: \(effectiveDate)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(introduction)
                        .font(.body)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.body)
                    }
                }
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
