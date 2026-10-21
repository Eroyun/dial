import Foundation

@main
struct AULAConnectionSelectionTests {
    static func main() {
        var selection = (id: "", explicit: false)
        func update(_ ids: [String]) {
            selection = AULAConnectionSelection.resolve(ids: ids, selected: selection.id, explicit: selection.explicit)
        }
        update([])
        precondition(selection.id.isEmpty && !selection.explicit, "No USB device clears selection")
        update(["101"])
        precondition(selection.id == "101" && !selection.explicit, "One device selects automatically")
        update(["101", "102"])
        precondition(selection.id.isEmpty, "Automatic choice does not survive ambiguous connection")
        update(["102"])
        precondition(selection.id == "102" && !selection.explicit, "Remaining single device selects automatically")
        selection = ("102", true)
        update(["101", "102"])
        precondition(selection.id == "102" && selection.explicit, "Explicit choice survives while its exact ID is present")
        update(["101", "103"])
        precondition(selection.id.isEmpty && !selection.explicit, "Disappearing explicit choice never moves to a replacement in an ambiguous set")
        selection = ("102", true)
        update(["103"])
        precondition(selection.id == "103" && !selection.explicit, "Reconnected registry ID becomes a new automatic single-device choice")
        update(["103", "104"])
        precondition(selection.id.isEmpty, "Replacement automatic choice still requires choice when another device connects")
        selection = ("103", true)
        update([])
        precondition(selection.id.isEmpty && !selection.explicit, "Unplug clears explicit ownership")

        var refresh = AULAConnectionRefreshState()
        precondition(!refresh.active, "Constructing the state is passive")
        precondition(!refresh.request(busy: true) && !refresh.childExited(), "Inactive requests do not schedule follow-up children")
        refresh.open()
        precondition(refresh.request(busy: false), "Opening an idle window can refresh immediately")
        for _ in 0..<20 { precondition(!refresh.request(busy: true), "Busy operations cannot overlap") }
        precondition(refresh.childExited(), "Connection burst schedules one refresh after status/sync/cancel exit")
        precondition(!refresh.childExited(), "Queued refresh is consumed exactly once")
        _ = refresh.request(busy: true)
        refresh.close()
        precondition(!refresh.childExited(), "Closing drops pending connection work")
        refresh.open()
        _ = refresh.request(busy: true)
        refresh.close()
        refresh.open()
        precondition(!refresh.request(busy: true), "Quick reopen waits for the cancelling child")
        precondition(refresh.childExited(), "Quick reopen refreshes after actual child exit")
        precondition(!refresh.childExited(), "Quick reopen has only one follow-up")
        print("AULA connection selection and refresh lifecycle checks passed")
    }
}
